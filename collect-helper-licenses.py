#!/usr/bin/env python3
"""Collect helper notices and corresponding-source inputs; never compile or publish.

Requires Python 3.11+, Git, and the installed Rust toolchain used to build the
helper. Inputs and Cargo caches are read-only. Output must be a new directory.
Original project code: GPL-3.0; upstream files retain their own licenses.
"""
from __future__ import annotations
import argparse
import ast
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
import urllib.parse
import urllib.request

HELPER_INPUTS = {
    'standalone-helper.rs': 'crates/xodus-cli/examples/standalone_helper.rs',
    'standalone-xvd.rs': 'crates/xodus-cli/examples/standalone_xvd.rs',
    'LICENSES/XVD-GreenGamesPublicKey.rsa': 'crates/xodus-cli/examples/standalone_xvd_key.rsa',
}

NOTICE = re.compile(r'(?i)^(licenses?|licences?|copying|notices?|copyright|patents)(?:$|[._-])')
TARGET = 'aarch64-apple-darwin'
EAPPX_EXCLUDED = {'.cer', '.emsix', '.emsixbundle', '.msix', '.msixbundle', '.p7x'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(args, cwd=None):
    proc = subprocess.run(args, cwd=cwd, capture_output=True, timeout=30)
    if proc.returncode:
        raise RuntimeError(f'{Path(str(args[0])).name} failed: ' + proc.stderr.decode(errors='replace')[-2000:])
    return proc.stdout


class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Refusing a non-HTTPS redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url):
    if not url.startswith('https://'):
        raise ValueError('Source URL must use HTTPS')
    with urllib.request.build_opener(HTTPSOnly()).open(url, timeout=30) as response:
        data = response.read(128 * 1024 * 1024 + 1)
    if len(data) > 128 * 1024 * 1024:
        raise ValueError('Source archive exceeded 128 MiB limit')
    return data


def safe_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or '..' in path.parts or '\\' in name:
        raise ValueError('Unsafe archive path')
    return path


def archive_files(data, strip_root=False, skip_nonregular=False):
    """Read regular file bytes without extracting paths or following links."""
    result = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
        for member in archive:
            path = safe_name(member.name)
            if strip_root:
                path = PurePosixPath(*path.parts[1:])
            if member.isdir() or str(path) == '.':
                continue
            if not member.isfile():
                if skip_nonregular:
                    continue  # Notice-only scan: never extract/follow upstream fixture links.
                raise ValueError('Nonregular source archive entry requires review: ' + str(path))
            if str(path) in result:
                raise ValueError('Duplicate archive file: ' + str(path))
            result[str(path)] = (archive.extractfile(member).read(), member.mode)
    return result


def tar_bytes(files, prefix):
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode='wb', mtime=0, filename='') as gz:
        with tarfile.open(fileobj=gz, mode='w') as archive:
            for name, (data, mode) in sorted(files.items()):
                safe_name(name)
                info = tarfile.TarInfo(prefix + '/' + name)
                info.size, info.mode, info.mtime = len(data), mode, 0
                archive.addfile(info, io.BytesIO(data))
    return output.getvalue()


def write(root, name, data):
    safe_name(name)
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return {'path': name, 'sha256': digest(data), 'bytes': len(data)}


def notice_file(name):
    path = PurePosixPath(name)
    return bool(NOTICE.match(path.name) or any(p.lower() in ('licenses', 'licences') for p in path.parts[:-1]))


def github_identity(repository, commit):
    parsed = urllib.parse.urlparse(repository)
    parts = parsed.path.strip('/').split('/')
    if parsed.scheme != 'https' or parsed.hostname != 'github.com' or len(parts) < 2:
        raise ValueError('No supported immutable GitHub notice source')
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Source commit is not a full Git SHA')
    return parts[0] + '/' + parts[1].removesuffix('.git'), commit


def project_config(root):
    for node in ast.parse((root / 'bootstrap-sources.py').read_text()).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'PROJECTS' for t in node.targets):
            return ast.literal_eval(node.value)['xodus']
    raise ValueError('Pinned Xodus project not found')


def validate_xodus(project, source, config, upstream_bytes):
    """Replay the public patches in a scratch tree; read the supplied source only."""
    expected = archive_files(upstream_bytes, strip_root=True)
    with tempfile.TemporaryDirectory(prefix='bedrock-helper-source-check-') as folder:
        stage = Path(folder)
        for name, (data, mode) in expected.items():
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(mode)
        for patch in config['patches']:
            file = project / 'patches' / patch
            run(['git', 'apply', '--check', str(file)], cwd=stage)
            run(['git', 'apply', str(file)], cwd=stage)
        shutil.copyfile(project / 'patches/Cargo.lock', stage / 'Cargo.lock')
        for source_name, destination in HELPER_INPUTS.items():
            original = project / source_name
            if original.is_symlink() or not original.is_file():
                raise ValueError('Missing regular project helper input: ' + source_name)
            helper = stage / destination
            helper.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, helper)
        expected = {}
        for path in stage.rglob('*'):
            if path.is_symlink():
                raise ValueError('Patched source contains a symlink')
            if path.is_file():
                expected[str(path.relative_to(stage))] = (path.read_bytes(), path.stat().st_mode & 0o777)
        observed = set()
        for base, dirs, names in os.walk(source, followlinks=False):
            dirs[:] = [d for d in dirs if d not in ('.git', 'target')]
            for directory in dirs:
                if (Path(base) / directory).is_symlink():
                    raise ValueError('Source directory symlink requires review')
            for name in names:
                path = Path(base) / name
                if path.is_symlink() or not path.is_file():
                    raise ValueError('Nonregular source file')
                rel = str(path.relative_to(source))
                if rel not in expected or path.read_bytes() != expected[rel][0]:
                    raise ValueError('Source differs from pinned project inputs: ' + rel)
                observed.add(rel)
        if observed != set(expected):
            raise ValueError('Pinned source files are missing')
    return expected


def collect(args):
    source, helper, project, output = (p.resolve() for p in (args.xodus_source, args.helper, args.project_root, args.output))
    if args.output.exists() or args.output.is_symlink():
        raise ValueError('Output must be a new directory')
    if not source.is_dir() or not helper.is_file():
        raise ValueError('Source directory and built helper must exist')
    if output.is_relative_to(source) or output.is_relative_to(project):
        raise ValueError('Use an isolated output outside project/source inputs')
    output.mkdir(parents=True)
    config = project_config(project)
    repo, revision = github_identity(config['url'].removesuffix('.git'), config['commit'])
    upstream_url = f'https://codeload.github.com/{repo}/tar.gz/{revision}'
    upstream = fetch(upstream_url)
    validated_source = validate_xodus(project, source, config, upstream)
    initial_helper_sha256 = digest(helper.read_bytes())
    source_record = write(output, 'source/xodus-patched-source.tar.gz', tar_bytes(validated_source, 'xodus'))
    source_record.update(upstream=upstream_url, upstream_archive_sha256=digest(upstream), upstream_commit=revision,
                         source_files=[{'path': n, 'sha256': digest(d)} for n, (d, _) in sorted(validated_source.items())])
    cargo = ['rustup', 'run', args.toolchain, 'cargo']
    common = ['--locked', '--offline', '--manifest-path', str(source / 'Cargo.toml')]
    if args.no_default_features:
        common.append('--no-default-features')
    metadata_bytes = run(cargo + ['metadata', *common, '--format-version', '1', '--filter-platform', TARGET])
    tree_bytes = run(cargo + ['tree', *common, '--target', TARGET, '-p', 'xodus-cli', '--edges', 'normal,build', '--prefix', 'depth', '--format', '{p}|{f}'])
    write(output, 'internal/cargo-metadata.json', metadata_bytes)
    write(output, 'internal/cargo-tree.txt', tree_bytes)
    metadata = json.loads(metadata_bytes)
    selected = {}
    for line in tree_bytes.decode().splitlines():
        match = re.match(r'^\d+([^ ]+) v([^ |]+).*?\|(.*?)(?: \(\*\))?$', line)
        if match:
            selected.setdefault((match[1], match[2]), set()).update(filter(None, match[3].split(',')))
    lock_bytes = (source / 'Cargo.lock').read_bytes()
    locked = {(p['name'], p['version']): p for p in tomllib.loads(lock_bytes.decode())['package']}
    rows, input_records, notices_cache = [], [], {}
    for package in metadata['packages']:
        key = package['name'], package['version']
        if key not in selected:
            continue
        root = Path(package['manifest_path']).parent
        pin = locked[key]
        origin = pin.get('source', 'workspace')
        row = {'name': key[0], 'version': key[1], 'source': origin, 'declared_license': package['license'],
               'repository': package.get('repository'), 'features': sorted(selected[key]), 'notices': []}
        files = {}
        if origin.startswith('registry+'):
            name = f'{key[0]}-{key[1]}.crate'
            cache = root.parents[2] / 'cache' / root.parent.name / name
            data = cache.read_bytes()
            if digest(data) != pin['checksum']:
                raise ValueError('Crate checksum mismatch: ' + name)
            record = write(output, 'source/registry/' + name, data)
            record.update(kind='registry', name=key[0], version=key[1], url=f'https://static.crates.io/crates/{key[0]}/{name}')
            input_records.append(record)
            row['crate_sha256'] = pin['checksum']
            files = archive_files(data, strip_root=True)
            if '.cargo_vcs_info.json' in files:
                row['crate_vcs_info'] = json.loads(files['.cargo_vcs_info.json'][0])
        elif origin.startswith('git+'):
            commit = origin.rsplit('#', 1)[1]
            raw = run(['git', '-C', str(root), 'archive', '--format=tar', commit])
            files = archive_files(raw)
            excluded = []
            if key[0] == 'eappx':
                for name in list(files):
                    if name.startswith('testdata/') and (PurePosixPath(name).suffix.lower() in EAPPX_EXCLUDED or name == 'testdata/keys.txt'):
                        excluded.append(name)
                        del files[name]
            record = write(output, f'source/git/{key[0]}-{commit}.tar.gz', tar_bytes(files, key[0]))
            record.update(kind='git', name=key[0], source=origin, commit=commit, exclusions=excluded)
            input_records.append(record)
            row['git_revision'] = commit
        else:
            files = {'LICENSE.workspace': ((source / 'LICENSE').read_bytes(), 0o644)}
            row['license_basis'] = 'Xodus workspace root license; exact patched source preserved separately.'
        explicit = package.get('license_file')
        if explicit and Path(explicit).is_absolute():
            explicit = str(Path(explicit).relative_to(root))
        for name, (data, _) in sorted(files.items()):
            if notice_file(name) or name == explicit:
                data.decode('utf-8')
                record = write(output, f'notices/{key[0]}-{key[1]}/{name}', data)
                record['source_path'] = name
                row['notices'].append(record)
        if not row['notices'] and origin.startswith('registry+'):
            try:
                repo, rev = github_identity(row['repository'], row['crate_vcs_info']['git']['sha1'])
                url = f'https://codeload.github.com/{repo}/tar.gz/{rev}'
                if url not in notices_cache:
                    raw = fetch(url)
                    record = write(output, f'notice-evidence/{repo.replace("/", "--")}-{rev}.tar.gz', raw)
                    record['url'] = url
                    record['scope'] = 'Notice evidence only; nonregular archive entries ignored and never followed'
                    notices_cache[url] = record, archive_files(raw, strip_root=True, skip_nonregular=True)
                record, upstream_files = notices_cache[url]
                prefix = PurePosixPath(row['crate_vcs_info'].get('path_in_vcs', ''))
                ancestors = {str(prefix), '.', ''} | {str(p) for p in prefix.parents}
                for name, (data, _) in sorted(upstream_files.items()):
                    path = PurePosixPath(name)
                    license_dir = path.parent.name.lower() in ('licenses', 'licences') and str(path.parent.parent) in ancestors
                    if not ((NOTICE.match(path.name) and str(path.parent) in ancestors) or license_dir):
                        continue
                    data.decode('utf-8')
                    notice = write(output, f'notices/{key[0]}-{key[1]}/upstream/{name}', data)
                    notice.update(source_url=f'https://raw.githubusercontent.com/{repo}/{rev}/{name}', source_archive=record)
                    row['notices'].append(notice)
            except (OSError, ValueError, KeyError, TypeError) as exc:
                row['upstream_notice_error'] = str(exc)
        # These exact crates explicitly grant an Apache-2.0 choice; preserve the
        # original grant, plus the unchanged standard license, without inventing MIT attribution.
        if not row['notices'] and key in (('cms', '0.2.3'), ('system-configuration-sys', '0.5.0')):
            if 'Apache-2.0' not in (row['declared_license'] or ''):
                raise ValueError('Expected Apache license choice absent')
            url = 'https://www.apache.org/licenses/LICENSE-2.0.txt'
            apache = fetch(url)
            if b'Version 2.0, January 2004' not in apache:
                raise ValueError('Unexpected Apache standard license')
            notice = write(output, f'notices/{key[0]}-{key[1]}/LICENSE-APACHE-2.0.txt', apache)
            notice['source_url'] = url
            row['notices'].append(notice)
            grant_path = 'README.md' if key[0] == 'cms' else 'src/lib.rs'
            grant = files[grant_path][0]
            if key[0] == 'system-configuration-sys':
                grant = b'\n'.join(grant.splitlines()[:8]) + b'\n'
            notice = write(output, f'notices/{key[0]}-{key[1]}/LICENSE-GRANT.txt', grant)
            notice.update(source_path=grant_path, source_crate_sha256=row['crate_sha256'])
            row['notices'].append(notice)
            row['selected_license'] = 'Apache-2.0'
        row['notice_status'] = 'collected; source/per-file scope review remains' if row['notices'] else 'unresolved; no full upstream license/copyright text found at exact revision'
        rows.append(row)
    if {(r['name'], r['version']) for r in rows} != set(selected):
        raise ValueError('Target graph could not be completely mapped')
    controls = [*HELPER_INPUTS, 'LICENSES/XVD-PUBLIC-KEY-PROVENANCE.txt', 'standalone-setup.py', 'bootstrap-sources.py', 'build-helper.sh', 'LICENSE', 'THIRD_PARTY.md', 'SECURITY.md', 'patches/Cargo.lock']
    controls += ['patches/' + name for name in config['patches']]
    for name in controls:
        record = write(output, 'source/project-build-materials/' + name, (project / name).read_bytes())
        record['kind'] = 'local-project'
        input_records.append(record)
    # Preserve bounded native build/link observations. Never execute the helper.
    loads = run(['otool', '-L', str(helper)]).decode().splitlines()[1:]
    symbol_text = run(['nm', '-u', str(helper)]).decode()
    native = {'loads': [line.strip() for line in loads], 'undefined_openssl_family_symbols': sum(any(s in line for s in ('SSL_', 'OPENSSL_', 'CRYPTO_', 'EVP_', 'BIO_', 'X509_')) for line in symbol_text.splitlines()), 'build_records': []}
    build = helper.parent.parent / 'build' if helper.parent.name == 'examples' else None
    if build and build.is_dir():
        for family in ('openssl-sys', 'aws-lc-sys', 'ring', 'libz-ng-sys'):
            for record in sorted(build.glob(family + '-*/output')):
                data = record.read_bytes()
                lines = [line for line in data.decode().splitlines() if any(s in line for s in ('rustc-link-lib=', 'cargo:version', 'version:'))]
                native['build_records'].append({'crate': family, 'record_id': record.parent.name, 'full_record_sha256': digest(data), 'link_version_lines': lines})
    native['limitation'] = 'A sys crate build record is not proof of linked code. System-only load commands do not establish static OpenSSL. Source and notices are conservatively retained.'
    write(output, 'native-build-evidence.json', (json.dumps(native, indent=2) + '\n').encode())
    if digest(helper.read_bytes()) != initial_helper_sha256:
        raise ValueError('Helper changed during collection; retry with frozen inputs')
    for name, (data, _) in validated_source.items():
        if (source / name).is_symlink() or (source / name).read_bytes() != data:
            raise ValueError('Source changed during collection; retry with frozen inputs')
    for source_name, destination in HELPER_INPUTS.items():
        if (project / source_name).is_symlink() or (project / source_name).read_bytes() != validated_source[destination][0]:
            raise ValueError('Project helper input changed during collection: ' + source_name)
    index = {'schema': 1, 'status': 'source-and-notice-candidate-not-distribution-clearance', 'target': TARGET,
             'toolchain': args.toolchain, 'package': 'xodus-cli', 'example': 'standalone_helper', 'edges': ['normal', 'build'],
             'features': 'no-default-features' if args.no_default_features else 'default',
             'build_flags': ['--no-default-features'] if args.no_default_features else [],
             'helper_sha256': digest(helper.read_bytes()), 'lock_sha256': digest(lock_bytes),
             'xodus_source': source_record, 'source_inputs': input_records, 'packages': rows,
             'unresolved_notices': [r['name'] + '@' + r['version'] for r in rows if not r['notices']],
             'upstream_notice_sources': [record for record, _ in notices_cache.values()],
             'limitations': ['No isolated rebuild from output performed.', 'No compiled target, installed game, user credentials, saves or private logs copied.', 'Unchanged published source crates can contain public test certificates/keys; these are upstream fixtures.', 'Selected macOS normal/build sources supplied; unrelated optional/other-platform/dev lockfile packages are not included.', 'GPL corresponding-source availability and per-file notices still need release review.', 'internal/ contains machine-specific cache paths and is not a public payload.']}
    write(output, 'index.json', (json.dumps(index, indent=2) + '\n').encode())
    write(output, 'README.md', readme(args.toolchain, args.no_default_features, index['unresolved_notices']).encode())
    write(output, 'reconstruct.py', RECONSTRUCT.encode())
    print(json.dumps({'packages': len(rows), 'notice_texts': sum(len(r['notices']) for r in rows), 'source_inputs': len(input_records) + 1, 'unresolved_notices': index['unresolved_notices']}, indent=2))


def readme(toolchain, no_default_features=False, unresolved_notices=()):
    return f'''# Helper notice and corresponding-source candidate

Verify/reconstruct into a new directory using Python 3.11+:

```sh
python3 reconstruct.py /absolute/path/to/new-source-directory
cd /absolute/path/to/new-source-directory/xodus
cargo +{toolchain} build --release --locked {'--no-default-features ' if no_default_features else ''}-j 4 -p xodus-cli --example standalone_helper
```

`reconstruct.py` checks every recorded source/archive hash before extraction. It
restores patched Xodus source, exact git source snapshots and original registry
`.crate` archives. It does not execute source or compile. Provision the recorded
Rust toolchain, protoc, macOS SDK/command-line tools, and native build prerequisites
separately. Cargo may fetch dependencies using the original pinned lockfile;
these archives are source materials, **not a configured offline Cargo vendor tree**.
A clean isolated reconstruction/build remains required before a reproducibility claim.

The generator replays the pinned upstream Xodus patches in a temporary directory
and compares every supplied source file, excluding only `.git` and `target`.
Unknown source files, symlinks, changed files and missing files cause failure.
The helper's hash binds the report to the supplied binary; it does not prove
that this binary was built from these sources without trusted build evidence.

`index.json` records the selected target/features, crate checksums, Git commits,
source URLs, source/notice hashes and unresolved license text. The conservative
normal/build graph includes build tools and proc-macros. It is not a linker-level
inventory. Native build observations are in `native-build-evidence.json`.

Seven eappx prebuilt sample-package/certificate/signature/content-key fixtures
are excluded when present and explicitly listed in its source record. Library
source is preserved; the omitted fixture tests cannot run from this candidate.
Unchanged published source crates may contain public test keys/certificates;
these are upstream fixtures, not private account credentials.

Unknown/missing notices remain explicit; do not invent copyright holders or use
moving upstream HEAD as evidence for old package versions. Unresolved notices
in this selected graph: {', '.join(unresolved_notices) or 'none recorded'}.
This is a bounded evidence inventory, not a blanket license assurance.

`internal/` contains local machine paths and is private build evidence. Bulk
notices/source archives are generated build output; never add these directories
recursively to the public source allowlist or the app bundle. No game, account,
Keychain, save or compiled target data is collected. This is preparation evidence,
not blanket legal assurance or permission to publish.
'''


RECONSTRUCT = r'''#!/usr/bin/env python3
"""Verify and reconstruct source materials into a new directory; never compile."""
import hashlib,io,json,sys,tarfile
from pathlib import Path,PurePosixPath
root=Path(__file__).resolve().parent
if len(sys.argv)!=2:raise SystemExit('Usage: reconstruct.py NEW_DIRECTORY')
destination=Path(sys.argv[1]).absolute()
if destination.exists() or destination.is_symlink():raise SystemExit('Destination must not exist')
index=json.loads((root/'index.json').read_text())
records=[index['xodus_source'],*index['source_inputs']]
for record in records:
 path=root/record['path']
 if not path.resolve().is_relative_to(root):raise SystemExit('Unsafe source index path')
 if hashlib.sha256(path.read_bytes()).hexdigest()!=record['sha256']:raise SystemExit('Source hash mismatch: '+record['path'])
destination.mkdir(parents=True)
for record in records:
 data=(root/record['path']).read_bytes()
 if record is index['xodus_source'] or record.get('kind')=='git':
  prefix=destination if record is index['xodus_source'] else destination/'git-sources'
  with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
   for member in archive:
    path=PurePosixPath(member.name)
    if path.is_absolute() or '..' in path.parts or '\\' in member.name or not member.isfile():raise SystemExit('Unsafe archive member')
    target=prefix/str(path)
    target.parent.mkdir(parents=True,exist_ok=True)
    with target.open('xb') as out:out.write(archive.extractfile(member).read())
    target.chmod(member.mode&0o777)
 else:
  path=Path(record['path']).relative_to('source');target=destination/path;target.parent.mkdir(parents=True,exist_ok=True)
  with target.open('xb') as out:out.write(data)
print('Verified and reconstructed',len(records),'inputs; no build performed.')
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xodus-source', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--project-source', '--project-root', dest='project_root', type=Path, default=Path(__file__).resolve().parent,
                        help='Public project source; defaults to this script directory')
    parser.add_argument('--toolchain', default='1.98.0')
    parser.add_argument('--no-default-features', action='store_true',
                        help='Match standalone helper builds excluding the legacy eappx CLI feature')
    args = parser.parse_args()
    try:
        collect(args)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, tarfile.TarError) as exc:
        parser.exit(1, 'Collection stopped: ' + str(exc) + '\nPartial output is unverified; preserve it for diagnosis or choose a new output directory.\n')


if __name__ == '__main__':
    main()
