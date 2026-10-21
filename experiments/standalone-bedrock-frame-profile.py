#!/usr/bin/env python3
"""Reversibly enable the one validated frame-slab DLL over a verified refmove base.

Stage and restore only while the runtime is idle. The existing heap/refmove
records remain intact for rollback. Every replacement is atomic, with a recovery
journal written before the first runtime change. New builds are never promoted
by this helper unless their bytes equal the frozen, tested artifact.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STATUS = 'bedrock-frame-slab.json'
BACKUPS = 'bedrock-frame-slab-backups'
PROFILE = 'bedrock-frame-slab-1265203-v1'
ENVIRONMENT = 'BEDROCK_FRAME_SLAB'
TESTED_DLL_SHA = '24f230a1f029573e6726b7269e161a5da6e6527cc15a4b75e7e63e70661c1e33'
BASE_DLL_SHA = '3a5e665897b7e73d09f1e9062e88214c6f391da61ec625a0cd14efc124a2eb6c'
GAME_SHA = '4a92bfa3ce2428b40ee517b7c1125d9f6f79274382de03846351992663b2e2e4'
UNIX_SHA = 'ef5c2ace1c39bfbd6fd40e7c81e8c73094199dffc227ec7781322ea62967203e'
SOURCE_INPUTS_SHA = '5e18fefdd95a8712181e4f999e15032e08540d3e3b47e29ba59a325c761d2684'
EXACT_SOURCE_INPUTS_SHA = '6c96c839d418093257d55fd70b28ceec43cc9e58b11514e45198fbbbb3741b37'
PATCH_SHA = '4ae728f2528eee3a1be3850135fa6279926f7e22ba6d74cb97f33fa546b0f048'
EXACT_PATCH_SHA = 'd5d1add946840b8d503558b0c79c997a1c12710b68de54c64c38fbabb083f4ab'
RUNTIME_LOCKS = ('.wine-heap-reuse.lock', '.bedrock-refmove.lock')
SPEC = importlib.util.spec_from_file_location('frame_profile_refmove', ROOT / 'experiments/standalone-bedrock-refmove.py')
ref = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ref)
DLL, UNIX, MANIFEST = ref.DLL, ref.UNIX, ref.MANIFEST
sha, json_bytes = ref.sha, ref.json_bytes


def object_json(data, name):
    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RuntimeError('Duplicate JSON key in ' + name)
            result[key] = value
        return result
    result = json.loads(data, object_pairs_hook=unique)
    if type(result) is not dict:
        raise RuntimeError('Expected a JSON object in ' + name)
    return result


def read_file(runtime, relative, snapshots=None):
    path = ref.safe_path(runtime, relative)
    if not stat.S_ISREG(path.stat().st_mode):
        raise RuntimeError('Expected a regular file: ' + str(relative))
    data = path.read_bytes()
    if snapshots is not None:
        snapshots[str(relative)] = data
    return data


def unchanged(runtime, snapshots):
    for name, expected in snapshots.items():
        if read_file(runtime, name) != expected:
            raise RuntimeError('Runtime profile changed during verification: ' + name)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write(path, data, mode=0o644):
    """Use the existing atomic writer, then persist directory entries in order."""
    missing = []
    parent = path.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    ref.write(path, data, mode)
    sync_directory(path.parent)
    for directory in missing:
        sync_directory(directory.parent)


def game_identity(game):
    game = ref.canonical_directory(game)
    path = ref.safe_path(game, 'Minecraft.Windows.exe')
    before = path.stat()
    if not stat.S_ISREG(before.st_mode):
        raise RuntimeError('Expected a regular Minecraft executable')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != GAME_SHA:
        raise RuntimeError('Unsupported Minecraft executable checksum')
    stamp = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    identity = stamp(before)
    if stamp(path.stat()) != identity:
        raise RuntimeError('Minecraft executable changed during verification')
    return game, identity


def check_game_stamp(game, expected):
    path = ref.safe_path(game, 'Minecraft.Windows.exe')
    value = path.stat()
    if (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns) != expected:
        raise RuntimeError('Minecraft executable changed during verification')


def artifact_identity():
    return dict(format=1, profile=PROFILE, architecture='x86_64', wine_version='11.8',
                source_commit=ref.COMMIT, heap_source_sha256=ref.HEAP_SHA,
                source_inputs_sha256=SOURCE_INPUTS_SHA, base_source_inputs_sha256=EXACT_SOURCE_INPUTS_SHA,
                dll_sha256=TESTED_DLL_SHA, game_sha256=GAME_SHA, patch_sha256=PATCH_SHA,
                heap_patch_sha256=ref.HEAP_PATCH_SHA, refmove_patch_sha256=ref.PATCH_SHA,
                exact_current_patch_sha256=EXACT_PATCH_SHA, default_enabled=False, stageable=False,
                maximum_reserved_bytes=384 * 1024 * 1024,
                maximum_bytes_per_scope_per_pool=64 * 1024 * 1024,
                maximum_bytes_per_pool=128 * 1024 * 1024,
                control_format={'version': 1, 'size': 65664, 'threads': 512, 'thread_stride': 128},
                environment={'BEDROCK_FRAME_SLAB': '1', 'BEDROCK_FRAME_SLAB_CONTROL': 'fresh DOS file path',
                             'BEDROCK_FRAME_SLAB_CHUNK': [0, 4096, 16384, 65536],
                             'required_for_game': {'BEDROCK_PRIVATE_REFMOVE_15203': '1'},
                             'mutually_exclusive': ['BEDROCK_ALLOC_DIAG', 'BEDROCK_EXACT_CURRENT']})


def matches_identity(data, expected):
    # Canonical JSON preserves the distinction between booleans, floats and integers.
    return type(data) is dict and json_bytes({key: data.get(key) for key in expected}) == json_bytes(expected)


def verified_artifact(folder):
    folder = ref.canonical_directory(folder)
    dll = read_file(folder, 'ntdll-frame-slab.dll')
    metadata_data = read_file(folder, 'manifest.json')
    metadata = object_json(metadata_data, 'artifact manifest')
    inputs = object_json(read_file(folder, 'source-inputs.json'), 'artifact source inputs')
    if (sha(dll) != TESTED_DLL_SHA or sha(json_bytes(inputs)) != SOURCE_INPUTS_SHA or
            inputs.get('dlls/ntdll/heap.c') != ref.HEAP_SHA or
            not matches_identity(metadata, artifact_identity()) or
            metadata.get('default_enabled') is not False or metadata.get('stageable') is not False):
        raise RuntimeError('Artifact byte/hash/source verification failed; only the frozen tested DLL is accepted')
    ref.validate_pe(dll)
    return dll, sha(metadata_data)


def baseline_identity(runtime, original, metadata_data, snapshots):
    """Validate the retained refmove chain against its original manifest, not the overlay."""
    if sha(original) != BASE_DLL_SHA or BASE_DLL_SHA != ref.TESTED_DLL_SHA:
        raise RuntimeError('Requires the exact verified refmove DLL baseline')
    ref.validate_pe(original)
    metadata = object_json(metadata_data, 'baseline runtime manifest')
    if (metadata.get('wine_source_revision') != ref.COMMIT or metadata.get('architecture') != 'x86_64' or
            metadata.get('wine_version') not in ('11.8', 'wine-11.8')):
        raise RuntimeError('Requires the pinned x86_64 WineGDK 11.8 runtime')
    modifications = metadata.get('local_modifications', {})
    if type(modifications) is not dict or 'frame_slab' in modifications:
        raise RuntimeError('Untracked or overlapping frame-slab baseline')
    declared = modifications.get('bedrock_refmove', {})
    if (type(declared) is not dict or
            not matches_identity(declared, ref.artifact_identity()) or
            declared.get('default_enabled') is not False or declared.get('requested_gate') is not True):
        raise RuntimeError('Requires a verified refmove-active baseline manifest')
    marker_data = read_file(runtime, ref.STATUS, snapshots)
    marker = object_json(marker_data, 'refmove marker')
    previous_dll, previous_manifest = ref.verified_backups(runtime, marker)
    # Track the old rollback files too, so activation cannot accept a concurrent mutation.
    if (read_file(runtime, marker['backup'], snapshots) != previous_dll or
            read_file(runtime, marker['manifest_backup'], snapshots) != previous_manifest):
        raise RuntimeError('Refmove backup changed during verification')
    if (marker.get('phase') != 'staged' or marker.get('requested_gate') is not True or
            marker.get('staged_manifest_sha256') != sha(metadata_data)):
        raise RuntimeError('Requires a fully staged refmove-active baseline')
    heap_data = read_file(runtime, ref.heap.STATUS, snapshots)
    heap_record = object_json(heap_data, 'heap marker')
    for entry in (heap_record, modifications.get('heap_reuse', {})):
        if (type(entry) is not dict or entry.get('dll_sha256') != ref.BASE_DLL_SHA or
                entry.get('source_commit') != ref.COMMIT or entry.get('heap_source_sha256') != ref.HEAP_SHA or
                entry.get('patch_sha256') != ref.HEAP_PATCH_SHA):
            raise RuntimeError('Retained heap source or profile identity mismatch')
    if marker.get('heap_marker_sha256') != sha(heap_data):
        raise RuntimeError('Retained heap marker checksum mismatch')
    if sha(read_file(runtime, UNIX, snapshots)) != UNIX_SHA:
        raise RuntimeError('Pinned Unix ntdll checksum mismatch')
    return metadata, marker_data, heap_data


def digest_field(record, name):
    value = record.get(name)
    if not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None:
        raise RuntimeError('Invalid checksum in staging marker: ' + name)
    return value


def declared_profile(requested, artifact_sha, lock_identity):
    return dict(artifact_identity(), requested_gate=requested,
                artifact_manifest_sha256=artifact_sha, launcher_lock=lock_identity)


def verified_journal(runtime, record, snapshots):
    required = dict(format=1, profile=PROFILE, dll_sha256=TESTED_DLL_SHA, previous_sha256=BASE_DLL_SHA,
                    game_sha256=GAME_SHA, unix_sha256=UNIX_SHA, environment=ENVIRONMENT,
                    source_inputs_sha256=SOURCE_INPUTS_SHA)
    if (not matches_identity(record, required) or
            type(record.get('format')) is not int or record.get('phase') not in ('prepared', 'staged') or
            type(record.get('requested_gate')) is not bool):
        raise RuntimeError('Unrecognized or mismatched frame-slab staging marker')
    if 'launcher_lock' not in record:
        raise RuntimeError('Missing launcher lock identity in staging marker')
    stored_lock = record['launcher_lock']
    if stored_lock is not None:
        if not isinstance(stored_lock, str) or not Path(stored_lock).is_absolute():
            raise RuntimeError('Invalid launcher lock path in staging marker')
        if str(ref.no_symlink_path(stored_lock)) != stored_lock:
            raise RuntimeError('Noncanonical launcher lock path in staging marker')
    derived = launcher_lock_path(runtime)
    if derived is not None and stored_lock != str(derived):
        raise RuntimeError('Launcher lock identity mismatch in staging marker')
    for key in ('previous_mode', 'previous_manifest_mode'):
        if type(record.get(key)) is not int or not 0 <= record[key] <= 0o7777:
            raise RuntimeError('Invalid backup mode in staging marker')
    for key in ('previous_manifest_sha256', 'staged_manifest_sha256', 'refmove_marker_sha256',
                'heap_marker_sha256', 'artifact_manifest_sha256'):
        digest_field(record, key)
    directory = Path(BACKUPS) / BASE_DLL_SHA
    expected_paths = {'backup': str(directory / 'ntdll.dll'),
                      'manifest_backup': str(directory / ('build-manifest.' + record['previous_manifest_sha256'] + '.json'))}
    for key, expected in expected_paths.items():
        ref.safe_path(runtime, record[key])
        if record[key] != expected:
            raise RuntimeError('Unexpected backup path in staging marker')
    original = read_file(runtime, record['backup'], snapshots)
    old_manifest = read_file(runtime, record['manifest_backup'], snapshots)
    if sha(original) != BASE_DLL_SHA or sha(old_manifest) != record['previous_manifest_sha256']:
        raise RuntimeError('Backup checksum mismatch')
    for name, mode_key in (('backup', 'previous_mode'), ('manifest_backup', 'previous_manifest_mode')):
        if stat.S_IMODE(ref.safe_path(runtime, record[name]).stat().st_mode) != record[mode_key]:
            raise RuntimeError('Backup permissions differ from staging marker')
    metadata, refmove_data, heap_data = baseline_identity(runtime, original, old_manifest, snapshots)
    if sha(refmove_data) != record['refmove_marker_sha256'] or sha(heap_data) != record['heap_marker_sha256']:
        raise RuntimeError('Retained refmove or heap record changed since staging')
    metadata['local_modifications']['frame_slab'] = declared_profile(
        record['requested_gate'], record['artifact_manifest_sha256'], record['launcher_lock'])
    staged_manifest = json_bytes(metadata)
    if sha(staged_manifest) != record['staged_manifest_sha256']:
        raise RuntimeError('Staged runtime manifest identity mismatch')
    return original, old_manifest, staged_manifest


def check_update_locks(runtime):
    if any(ref.safe_path(runtime, name).exists() for name in RUNTIME_LOCKS):
        raise RuntimeError('Runtime profile update in progress; activation refused')


def verify_staged(runtime, game, status_data, allow_owned_locks=False):
    if not allow_owned_locks:
        check_update_locks(runtime)
    snapshots = {STATUS: status_data}
    record = object_json(status_data, 'frame-slab staging marker')
    _, _, expected_manifest = verified_journal(runtime, record, snapshots)
    if record['phase'] != 'staged':
        raise RuntimeError('Partial frame-slab profile; restore before activation')
    if read_file(runtime, MANIFEST, snapshots) != expected_manifest:
        raise RuntimeError('Staged runtime manifest checksum or identity mismatch')
    if sha(read_file(runtime, DLL, snapshots)) != TESTED_DLL_SHA:
        raise RuntimeError('Staged frame-slab DLL checksum mismatch')
    game, identity = game_identity(game)
    unchanged(runtime, snapshots)
    check_game_stamp(game, identity)
    if not allow_owned_locks:
        check_update_locks(runtime)
    return record['requested_gate']


def verified_activation(runtime, game):
    """Read-only verification; True only for a complete explicitly enabled profile.

    No artifact-directory dependency, inherited environment values, lsof call, or
    launcher-lock acquisition. The caller may already own that launcher's lock.
    Any corrupt or interrupted staged state raises RuntimeError, even if disabled.
    """
    try:
        runtime = ref.canonical_directory(runtime)
        status = ref.safe_path(runtime, STATUS)
        if not status.exists():
            return False
        return verify_staged(runtime, game, read_file(runtime, STATUS))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise RuntimeError('Cannot verify frame-slab activation: ' + str(error)) from error


def launcher_lock_path(runtime, explicit=None):
    derived = runtime.parent / 'launcher.lock' if runtime.name == 'wine' and runtime.parent.name == 'standalone' else None
    if explicit is not None:
        explicit = ref.no_symlink_path(explicit)
        if derived is not None and explicit != derived:
            raise RuntimeError('Explicit launcher lock differs from the runtime launcher lock')
        return explicit
    return derived


def launcher_lock_identity(path):
    return str(path) if path is not None else None


@contextmanager
def launcher_lock(path):
    if path is None:
        yield
        return
    ref.canonical_directory(path.parent)
    path = ref.no_symlink_path(path)
    if path.exists() and not stat.S_ISREG(path.stat().st_mode):
        raise RuntimeError('Launcher lock must be a regular file')
    fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('Another standalone setup or game session owns the launcher lock') from error
        yield
    finally:
        os.close(fd)  # Keep its inode: normal launchers use a persistent flock file.


def restore_locked(runtime, record, status, lock_path):
    snapshots = {STATUS: read_file(runtime, STATUS)}
    original, old_manifest, staged_manifest = verified_journal(runtime, record, snapshots)
    if record.get('launcher_lock') != launcher_lock_identity(lock_path):
        raise RuntimeError('Restore requires the same launcher lock used for staging; pass --launcher-lock when needed')
    target, metadata = ref.safe_path(runtime, DLL), ref.safe_path(runtime, MANIFEST)
    if sha(read_file(runtime, DLL, snapshots)) not in (TESTED_DLL_SHA, BASE_DLL_SHA):
        raise RuntimeError('DLL changed since staging; refusing to overwrite')
    if read_file(runtime, MANIFEST, snapshots) not in (old_manifest, staged_manifest):
        raise RuntimeError('Runtime manifest changed since staging; refusing to overwrite')
    unchanged(runtime, snapshots)
    write(target, original, record['previous_mode'])
    write(metadata, old_manifest, record['previous_manifest_mode'])
    if read_file(runtime, DLL) != original or read_file(runtime, MANIFEST) != old_manifest:
        raise RuntimeError('Restore verification failed; recovery marker retained')
    unchanged(runtime, {key: value for key, value in snapshots.items() if key not in (str(DLL), MANIFEST)})
    status.unlink()
    sync_directory(status.parent)
    print('Restored the exact refmove runtime; retained its original heap and refmove records.')


def stage(args, restore=False):
    """Stage defaults to an explicit enable request; restore needs no game/artifact."""
    runtime = ref.canonical_directory(args.wine)
    lock_path = launcher_lock_path(runtime, getattr(args, 'launcher_lock', None))
    with launcher_lock(lock_path), ref.runtime_lock(runtime):
        ref.check_runtime(runtime)
        ref.refuse_active(runtime)
        status = ref.safe_path(runtime, STATUS)
        if restore:
            restore_locked(runtime, object_json(read_file(runtime, STATUS), 'frame-slab staging marker'), status, lock_path)
            return
        if status.exists():
            record_data = read_file(runtime, STATUS)
            record = object_json(record_data, 'frame-slab staging marker')
            if record.get('launcher_lock') != launcher_lock_identity(lock_path):
                raise RuntimeError('Existing profile used a different launcher lock')
            if not verify_staged(runtime, args.game_dir, record_data, allow_owned_locks=True):
                raise RuntimeError('Existing profile is disabled; restore before staging again')
            print('Frame-slab profile is already staged and verified.')
            return
        dll, artifact_sha = verified_artifact(args.artifact)
        snapshots = {}
        original = read_file(runtime, DLL, snapshots)
        old_manifest = read_file(runtime, MANIFEST, snapshots)
        metadata, refmove_data, heap_data = baseline_identity(runtime, original, old_manifest, snapshots)
        game, identity = game_identity(args.game_dir)
        backup_dir = Path(BACKUPS) / BASE_DLL_SHA
        record = dict(format=1, profile=PROFILE, phase='prepared', requested_gate=True,
                      dll_sha256=TESTED_DLL_SHA, previous_sha256=BASE_DLL_SHA, game_sha256=GAME_SHA,
                      unix_sha256=UNIX_SHA, source_inputs_sha256=SOURCE_INPUTS_SHA, environment=ENVIRONMENT,
                      previous_manifest_sha256=sha(old_manifest), artifact_manifest_sha256=artifact_sha,
                      previous_mode=stat.S_IMODE(ref.safe_path(runtime, DLL).stat().st_mode),
                      previous_manifest_mode=stat.S_IMODE(ref.safe_path(runtime, MANIFEST).stat().st_mode),
                      refmove_marker_sha256=sha(refmove_data), heap_marker_sha256=sha(heap_data),
                      launcher_lock=launcher_lock_identity(lock_path), backup=str(backup_dir / 'ntdll.dll'),
                      manifest_backup=str(backup_dir / ('build-manifest.' + sha(old_manifest) + '.json')))
        metadata['local_modifications']['frame_slab'] = declared_profile(True, artifact_sha, record['launcher_lock'])
        staged_manifest = json_bytes(metadata)
        record['staged_manifest_sha256'] = sha(staged_manifest)
        unchanged(runtime, snapshots)
        check_game_stamp(game, identity)
        for key, data, mode in (('backup', original, record['previous_mode']),
                                ('manifest_backup', old_manifest, record['previous_manifest_mode'])):
            path = ref.safe_path(runtime, record[key])
            if path.exists() and read_file(runtime, record[key]) != data:
                raise RuntimeError('Existing backup is corrupt')
            if path.exists() and stat.S_IMODE(path.stat().st_mode) != mode:
                raise RuntimeError('Existing backup permissions differ')
            if not path.exists():
                write(path, data, mode)
            if read_file(runtime, record[key]) != data or stat.S_IMODE(path.stat().st_mode) != mode:
                raise RuntimeError('Backup verification failed before journal creation')
        # Prepared journal + verified backups precede either mutable runtime file.
        write(status, json_bytes(record))
        write(ref.safe_path(runtime, DLL), dll, record['previous_mode'])
        write(ref.safe_path(runtime, MANIFEST), staged_manifest, record['previous_manifest_mode'])
        if read_file(runtime, DLL) != dll or read_file(runtime, MANIFEST) != staged_manifest:
            raise RuntimeError('Stage verification failed; recovery marker retained')
        unchanged(runtime, {key: value for key, value in snapshots.items() if key not in (str(DLL), MANIFEST)})
        check_game_stamp(game, identity)
        record['phase'] = 'staged'
        write(status, json_bytes(record))
        print('Staged the frozen frame-slab profile; exact refmove rollback is retained.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('stage', 'restore'):
        p = sub.add_parser(command)
        p.add_argument('--wine', type=Path, required=True)
        p.add_argument('--launcher-lock', type=Path, help='Needed only when the launcher lock cannot be derived from runtime/standalone/wine')
        if command == 'stage':
            p.add_argument('--artifact', type=Path, required=True, help='Directory containing the frozen DLL, manifest.json and source-inputs.json')
            p.add_argument('--game-dir', type=Path, required=True)
    args = parser.parse_args()
    stage(args, restore=args.command == 'restore')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
