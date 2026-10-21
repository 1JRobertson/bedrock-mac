#!/usr/bin/env python3
"""Verify actual Wine build inputs against the pinned tree and selected patches."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify(source, root=ROOT):
    source = Path(os.path.abspath(source))
    if not source.is_dir() or any(path.is_symlink() for path in (source, *source.parents)):
        raise RuntimeError('Wine source must be a regular directory without symlink parents')
    bootstrap = root / 'tools/bootstrap-sources.py'
    if bootstrap.is_symlink():
        raise RuntimeError('Bootstrap configuration must not be a symlink')
    bootstrap_data = bootstrap.read_bytes()
    tree = ast.parse(bootstrap_data)
    projects = next(ast.literal_eval(node.value) for node in tree.body
                    if isinstance(node, ast.Assign) and
                    any(isinstance(target, ast.Name) and target.id == 'PROJECTS' for target in node.targets))
    project = projects['winegdk']
    patches = [root / 'patches' / name for name in project['patches']]
    patches += sorted((root / 'patches').glob('standalone-wine-*.patch'))
    if any(path.is_symlink() or not path.is_file() or path.parent != root / 'patches' for path in patches):
        raise RuntimeError('Wine patches must be regular files in the reviewed patch directory')
    patch_data = [(path, path.read_bytes()) for path in patches]
    # Do not let a caller's Git workspace/index variables select a different tree.
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)

    def git(*args, **kwargs):
        return subprocess.check_output(['git', '-c', 'core.fsmonitor=false', '-c', 'core.fileMode=true',
                                        '-C', str(source), *map(str, args)], env=env, stderr=subprocess.PIPE, **kwargs)

    if git('rev-parse', 'HEAD').decode().strip() != project['commit']:
        raise RuntimeError('Wine build source is not at the pinned revision')
    with tempfile.TemporaryDirectory(prefix='bedrock-wine-source-index-') as temporary:
        env['GIT_INDEX_FILE'] = str(Path(temporary) / 'index')
        git('read-tree', project['commit'])
        for path, data in patch_data:
            git('apply', '--cached', '-', input=data)
        # A separate index has no assume-unchanged or skip-worktree entries.
        # Include ignored/untracked headers and new modules: the compiler can use them.
        if git('diff', '--name-only', '--no-ext-diff', '--ignore-submodules=none').strip():
            raise RuntimeError('Wine build source differs from the reviewed patched tree')
        if git('ls-files', '--others', '-z'):
            raise RuntimeError('Unexpected untracked or ignored Wine source inputs')
        expected_tree = git('write-tree').decode().strip()
    return {'schema': 1, 'source_revision': project['commit'], 'patched_tree_sha1': expected_tree,
            'bootstrap_sha256': sha(bootstrap_data),
            'patches': {path.name: sha(data) for path, data in patch_data},
            'verifier_sha256': sha(Path(__file__).read_bytes())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--check-receipt', type=Path)
    args = parser.parse_args()
    try:
        identity = verify(args.source)
        if args.check_receipt and json.loads(args.check_receipt.read_bytes()) != identity:
            raise RuntimeError('Wine source identity changed during the build')
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix='.wine-source-', dir=args.output.parent)
            try:
                with os.fdopen(fd, 'w') as stream:
                    json.dump(identity, stream, indent=2); stream.write('\n')
                    stream.flush(); os.fsync(stream.fileno())
                os.replace(temporary, args.output)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        print('Verified Wine source: pinned revision and exact reviewed patched tree')
    except (OSError, ValueError, RuntimeError, KeyError, StopIteration, subprocess.CalledProcessError) as error:
        parser.exit(1, 'Wine source verification stopped: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
