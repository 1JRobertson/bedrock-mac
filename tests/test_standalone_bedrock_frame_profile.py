"""Reversible frame-profile tests using fake runtimes; no Wine, game, or real staging."""
import argparse
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('frame_profile', ROOT / 'standalone-bedrock-frame-profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)
ref = profile.ref


def pe(tag):
    data = bytearray(256)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 128)
    data[64:80] = b'Wine builtin DLL'
    data[128:132] = b'PE\0\0'
    struct.pack_into('<H', data, 132, 0x8664)
    struct.pack_into('<H', data, 152, 0x20b)
    data[-1] = tag
    return bytes(data)


class FrameProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(patch.stopall)
        self.root = Path(self.temp.name).resolve()
        self.runtime = self.root / 'runtime/standalone/wine'
        self.artifact, ref_artifact = self.root / 'artifact', self.root / 'ref-artifact'
        self.game_dir = self.root / 'game'; self.game_dir.mkdir()
        self.game = self.game_dir / 'Minecraft.Windows.exe'
        self.game.write_bytes(b'exact fake Minecraft executable')
        self.heap_dll, self.original, self.candidate = pe(1), pe(2), pe(3)
        self.unix = b'pinned Unix ntdll fixture'
        frame_inputs = {'dlls/ntdll/heap.c': ref.HEAP_SHA, 'dlls/ntdll/frame_adapter.h': 'fixture'}
        ref_inputs = {'dlls/ntdll/heap.c': ref.HEAP_SHA}
        for module, name, value in (
            (profile, 'TESTED_DLL_SHA', profile.sha(self.candidate)),
            (profile, 'BASE_DLL_SHA', profile.sha(self.original)),
            (profile, 'UNIX_SHA', profile.sha(self.unix)),
            (profile, 'GAME_SHA', profile.sha(self.game.read_bytes())),
            (profile, 'SOURCE_INPUTS_SHA', profile.sha(profile.json_bytes(frame_inputs))),
            (ref, 'TESTED_DLL_SHA', profile.sha(self.original)),
            (ref, 'BASE_DLL_SHA', profile.sha(self.heap_dll)),
            (ref, 'SOURCE_INPUTS_SHA', profile.sha(profile.json_bytes(ref_inputs))),
            (ref, 'GAME_SHA', profile.sha(self.game.read_bytes())), (ref, 'OUT', ref_artifact),
        ):
            patch.object(module, name, value).start()
        self.lsof = patch.object(ref.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')).start()
        heap_profile = dict(dll_sha256=ref.BASE_DLL_SHA, heap_source_sha256=ref.HEAP_SHA,
                            source_commit=ref.COMMIT, patch_sha256=ref.HEAP_PATCH_SHA)
        metadata = dict(wine_source_revision=ref.COMMIT, wine_version='11.8', architecture='x86_64',
                        unrelated={'preserve': 'original'}, local_modifications={'heap_reuse': heap_profile})
        ref.write(self.runtime / ref.DLL, self.heap_dll, 0o755)
        ref.write(self.runtime / ref.UNIX, self.unix)
        ref.write(self.runtime / ref.MANIFEST, ref.json_bytes(metadata), 0o640)
        ref.write(self.runtime / ref.heap.STATUS, ref.json_bytes(heap_profile))
        ref.write(ref_artifact / 'ntdll.dll', self.original)
        ref.write(ref_artifact / 'manifest.json', ref.json_bytes(ref.artifact_identity()))
        ref.write(ref_artifact / 'source-inputs.json', ref.json_bytes(ref_inputs))
        # Establish the baseline through the actual existing refmove stage API.
        with contextlib.redirect_stdout(io.StringIO()):
            ref.stage(argparse.Namespace(wine=self.runtime, enable=True))
        self.assertTrue(ref.verified_activation(self.runtime, self.game_dir))
        self.metadata = (self.runtime / ref.MANIFEST).read_bytes()
        self.ref_marker = (self.runtime / ref.STATUS).read_bytes()
        self.heap_marker = (self.runtime / ref.heap.STATUS).read_bytes()
        ref.write(self.artifact / 'ntdll-frame-slab.dll', self.candidate)
        ref.write(self.artifact / 'manifest.json', profile.json_bytes(profile.artifact_identity()))
        ref.write(self.artifact / 'source-inputs.json', profile.json_bytes(frame_inputs))
        self.args = argparse.Namespace(wine=self.runtime, artifact=self.artifact, game_dir=self.game_dir, launcher_lock=None)

    def stage(self):
        with contextlib.redirect_stdout(io.StringIO()):
            profile.stage(self.args)

    def restore(self):
        with contextlib.redirect_stdout(io.StringIO()):
            profile.stage(self.args, restore=True)

    def marker(self):
        return json.loads((self.runtime / profile.STATUS).read_bytes())

    def save_marker(self, value):
        ref.write(self.runtime / profile.STATUS, profile.json_bytes(value))

    def assert_retained(self):
        self.assertEqual((self.runtime / ref.STATUS).read_bytes(), self.ref_marker)
        self.assertEqual((self.runtime / ref.heap.STATUS).read_bytes(), self.heap_marker)
        self.assertEqual((self.runtime / ref.UNIX).read_bytes(), self.unix)

    def assert_original(self):
        self.assertEqual((self.runtime / ref.DLL).read_bytes(), self.original)
        self.assertEqual((self.runtime / ref.MANIFEST).read_bytes(), self.metadata)
        self.assert_retained()

    def test_success_verify_idempotence_and_exact_restore(self):
        self.stage(); self.assert_retained()
        record = (self.runtime / profile.STATUS).read_bytes()
        self.assertEqual(self.marker()['phase'], 'staged')
        self.assertTrue(self.marker()['requested_gate'])
        self.assertTrue(profile.verified_activation(self.runtime, self.game_dir))
        self.stage()
        self.assertEqual((self.runtime / profile.STATUS).read_bytes(), record)
        self.restore(); self.assert_original()
        self.assertFalse((self.runtime / profile.STATUS).exists())
        self.assertFalse(profile.verified_activation(self.runtime, self.game_dir))
        self.assertTrue(ref.verified_activation(self.runtime, self.game_dir))
        self.assertEqual(stat.S_IMODE((self.runtime / ref.DLL).stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE((self.runtime / ref.MANIFEST).stat().st_mode), 0o640)

    def test_activation_does_not_require_artifact_or_lsof(self):
        self.stage(); shutil.rmtree(self.artifact)
        self.lsof.reset_mock()
        self.assertTrue(profile.verified_activation(self.runtime, self.game_dir))
        self.lsof.assert_not_called()
        self.game.unlink()
        self.restore(); self.assert_original()

    def test_absent_marker_is_false_without_reading_game(self):
        self.game.unlink()
        self.assertFalse(profile.verified_activation(self.runtime, self.game_dir))

    def test_wrong_game_refused_before_stage_and_after_stage(self):
        original = self.game.read_bytes(); self.game.write_bytes(b'wrong build')
        with self.assertRaisesRegex(RuntimeError, 'Minecraft executable checksum'):
            self.stage()
        self.assert_original(); self.assertFalse((self.runtime / profile.STATUS).exists())
        self.game.write_bytes(original); self.stage(); self.game.write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'Minecraft executable checksum'):
            profile.verified_activation(self.runtime, self.game_dir)
        self.restore(); self.assert_original()

    def test_only_frozen_dll_and_source_artifact_are_accepted(self):
        dll = self.artifact / 'ntdll-frame-slab.dll'
        dll.write_bytes(pe(9))
        with self.assertRaisesRegex(RuntimeError, 'frozen tested DLL'):
            self.stage()
        dll.write_bytes(self.candidate)
        inputs = self.artifact / 'source-inputs.json'; inputs.write_text('{}')
        with self.assertRaisesRegex(RuntimeError, 'byte/hash/source'):
            self.stage()
        self.assert_original()

    def test_artifact_identity_is_checked_with_exact_json_types(self):
        target = self.artifact / 'manifest.json'; original = target.read_bytes()
        for field, value in (('source_commit', 'unknown'), ('patch_sha256', 'unknown'),
                             ('default_enabled', True), ('stageable', True), ('format', True)):
            with self.subTest(field=field):
                record = json.loads(original); record[field] = value; target.write_bytes(profile.json_bytes(record))
                with self.assertRaisesRegex(RuntimeError, 'byte/hash/source'):
                    self.stage()
        self.assert_original()

    def test_wrong_baseline_or_untracked_candidate_refused(self):
        target = self.runtime / ref.DLL
        for data in (pe(9), self.heap_dll, self.candidate):
            target.write_bytes(data)
            with self.assertRaisesRegex(RuntimeError, 'refmove DLL baseline'):
                self.stage()
        target.write_bytes(self.original); self.assert_original()

    def test_baseline_requires_enabled_complete_refmove_profile(self):
        path = self.runtime / ref.STATUS; original = path.read_bytes()
        for field, value in (('requested_gate', False), ('phase', 'prepared')):
            record = json.loads(original); record[field] = value; path.write_bytes(profile.json_bytes(record))
            with self.assertRaisesRegex(RuntimeError, 'refmove-active baseline'):
                self.stage()
        path.write_bytes(original); self.assert_original()

    def test_unix_module_is_pinned_at_stage_verify_and_restore(self):
        path = self.runtime / ref.UNIX; path.write_bytes(b'changed Unix module')
        with self.assertRaisesRegex(RuntimeError, 'Unix ntdll'):
            self.stage()
        path.write_bytes(self.unix); self.stage(); path.write_bytes(b'changed Unix module')
        for operation in (lambda: profile.verified_activation(self.runtime, self.game_dir), self.restore):
            with self.assertRaisesRegex(RuntimeError, 'Unix ntdll'):
                operation()
        self.assertEqual((self.runtime / ref.DLL).read_bytes(), self.candidate)

    def test_active_or_uncertain_runtime_refused(self):
        for result in (subprocess.CompletedProcess([], 0, 'p123\nn/module\n', ''),
                       subprocess.CompletedProcess([], 1, '', 'warning')):
            self.lsof.return_value = result
            with self.assertRaises(RuntimeError):
                self.stage()
            self.assert_original()
        self.assertIn(str(self.runtime / ref.DLL), self.lsof.call_args.args[0])
        self.assertIn(str(self.runtime / ref.UNIX), self.lsof.call_args.args[0])

    def test_shared_update_locks_are_respected(self):
        for name in profile.RUNTIME_LOCKS:
            lock = self.runtime / name; lock.write_text('another owner')
            with self.assertRaises(FileExistsError):
                self.stage()
            self.assertEqual(lock.read_text(), 'another owner')
            lock.unlink()
            self.assertFalse((self.runtime / profile.RUNTIME_LOCKS[0]).exists())
        self.assert_original()

    def test_derived_launcher_lock_blocks_stage_and_restore(self):
        lock = self.runtime.parent / 'launcher.lock'
        fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, 'launcher lock'):
                self.stage()
            self.assert_original()
            fcntl.flock(fd, fcntl.LOCK_UN)
            self.stage()
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(RuntimeError, 'launcher lock'):
                self.restore()
        finally:
            os.close(fd)
        self.assertTrue(lock.exists())
        self.restore(); self.assert_original()

    def test_cannot_bypass_derived_launcher_lock_with_another_path(self):
        self.args.launcher_lock = self.root / 'other.lock'
        with self.assertRaisesRegex(RuntimeError, 'differs'):
            self.stage()
        self.assertFalse(self.args.launcher_lock.exists())

    def test_explicit_lock_for_nonstandard_runtime_must_be_reused_for_restore(self):
        alternate = self.root / 'custom-runtime'
        self.runtime.rename(alternate); self.runtime = alternate; self.args.wine = alternate
        self.args.launcher_lock = self.root / 'custom-launcher.lock'
        self.stage(); self.assertTrue(profile.verified_activation(self.runtime, self.game_dir))
        lock = self.args.launcher_lock; self.args.launcher_lock = None
        with self.assertRaisesRegex(RuntimeError, 'same launcher lock'):
            self.restore()
        self.args.launcher_lock = lock; self.restore(); self.assert_original()

    def test_every_stage_write_can_be_interrupted_and_recovered(self):
        real_write = profile.write
        for moment in ('before', 'after'):
            for stop in range(1, 7):
                with self.subTest(moment=moment, stop=stop):
                    count = 0
                    def interrupted(path, data, mode=0o644):
                        nonlocal count
                        count += 1
                        if count == stop and moment == 'before': raise OSError('injected interruption')
                        real_write(path, data, mode)
                        if count == stop and moment == 'after': raise OSError('injected interruption')
                    with patch.object(profile, 'write', side_effect=interrupted):
                        with self.assertRaisesRegex(OSError, 'injected interruption'):
                            self.stage()
                    if (self.runtime / profile.STATUS).exists():
                        if self.marker()['phase'] == 'prepared':
                            with self.assertRaisesRegex(RuntimeError, 'Partial'):
                                profile.verified_activation(self.runtime, self.game_dir)
                        self.restore()
                    self.assert_original()
                    self.assertFalse((self.runtime / profile.STATUS).exists())
                    shutil.rmtree(self.runtime / profile.BACKUPS, ignore_errors=True)

    def test_every_restore_write_can_be_interrupted_and_retried(self):
        real_write = profile.write
        for moment in ('before', 'after'):
            for stop in (1, 2):
                self.stage(); count = 0
                def interrupted(path, data, mode=0o644):
                    nonlocal count
                    count += 1
                    if count == stop and moment == 'before': raise OSError('restore interruption')
                    real_write(path, data, mode)
                    if count == stop and moment == 'after': raise OSError('restore interruption')
                with patch.object(profile, 'write', side_effect=interrupted):
                    with self.assertRaisesRegex(OSError, 'restore interruption'):
                        self.restore()
                self.assertTrue((self.runtime / profile.STATUS).exists())
                self.restore(); self.assert_original()

    def test_restore_recovers_when_runtime_files_are_already_baseline(self):
        self.stage()
        ref.write(self.runtime / ref.DLL, self.original, 0o755)
        ref.write(self.runtime / ref.MANIFEST, self.metadata, 0o640)
        self.restore(); self.assert_original()

    def test_unknown_runtime_changes_are_not_overwritten(self):
        self.stage()
        for path, changed in ((self.runtime / ref.DLL, pe(9)),
                              (self.runtime / ref.MANIFEST, (self.runtime / ref.MANIFEST).read_bytes() + b'\n')):
            original = path.read_bytes(); path.write_bytes(changed)
            for operation in (self.restore, lambda: profile.verified_activation(self.runtime, self.game_dir)):
                with self.assertRaises(RuntimeError): operation()
            self.assertEqual(path.read_bytes(), changed)
            path.write_bytes(original)
        self.restore(); self.assert_original()

    def test_retained_records_must_remain_byte_identical(self):
        self.stage()
        for name in (ref.STATUS, ref.heap.STATUS):
            path = self.runtime / name; original = path.read_bytes(); path.write_bytes(original + b'\n')
            for operation in (self.restore, self.stage, lambda: profile.verified_activation(self.runtime, self.game_dir)):
                with self.assertRaises(RuntimeError): operation()
            path.write_bytes(original)
        self.restore(); self.assert_original()

    def test_backup_corruption_blocks_activation_restoration_and_repeat_stage(self):
        self.stage(); record = self.marker()
        for key in ('backup', 'manifest_backup'):
            path = self.runtime / record[key]; original = path.read_bytes(); path.write_bytes(b'corrupt')
            for operation in (self.restore, self.stage, lambda: profile.verified_activation(self.runtime, self.game_dir)):
                with self.assertRaisesRegex(RuntimeError, 'Backup checksum'): operation()
            path.write_bytes(original)
        self.restore(); self.assert_original()

    def test_old_refmove_backup_chain_is_rechecked(self):
        self.stage()
        old = json.loads(self.ref_marker)
        path = self.runtime / old['backup']; path.write_bytes(b'corrupt old backup')
        with self.assertRaisesRegex(RuntimeError, 'Backup checksum'):
            profile.verified_activation(self.runtime, self.game_dir)
        with self.assertRaisesRegex(RuntimeError, 'Backup checksum'):
            self.restore()

    def test_malformed_markers_refused(self):
        self.stage(); path = self.runtime / profile.STATUS
        for data in (b'{', b'[]', b'null', b'{"format":1,"format":1}'):
            path.write_bytes(data)
            with self.assertRaises(RuntimeError):
                profile.verified_activation(self.runtime, self.game_dir)

    def test_marker_identity_types_paths_and_permissions_are_validated(self):
        self.stage(); original = self.marker()
        for key, value in (('format', True), ('requested_gate', 1), ('phase', 'unknown'),
                           ('source_inputs_sha256', 'f' * 64), ('unix_sha256', 'f' * 64),
                           ('artifact_manifest_sha256', 'f' * 64),
                           ('game_sha256', 'f' * 64), ('previous_mode', True), ('previous_mode', 0o777),
                           ('backup', '../escape'), ('manifest_backup', '/absolute/path'),
                           ('backup', 'elsewhere'), ('previous_manifest_sha256', 'invalid'),
                           ('launcher_lock', '../lock'), ('launcher_lock', None)):
            with self.subTest(key=key, value=value):
                altered = dict(original); altered[key] = value; self.save_marker(altered)
                with self.assertRaises(RuntimeError):
                    profile.verified_activation(self.runtime, self.game_dir)
        self.save_marker(original); self.restore()

    def test_source_identity_cannot_be_changed_by_rehashing_current_metadata(self):
        self.stage()
        target = self.runtime / ref.MANIFEST; data = json.loads(target.read_bytes())
        data['local_modifications']['frame_slab']['patch_sha256'] = 'unknown'
        changed = profile.json_bytes(data); target.write_bytes(changed)
        record = self.marker(); record['staged_manifest_sha256'] = profile.sha(changed); self.save_marker(record)
        with self.assertRaisesRegex(RuntimeError, 'manifest identity'):
            profile.verified_activation(self.runtime, self.game_dir)

    def test_disabled_profile_still_requires_complete_integrity(self):
        self.stage(); record = self.marker(); record['requested_gate'] = False
        data = json.loads((self.runtime / ref.MANIFEST).read_bytes())
        data['local_modifications']['frame_slab']['requested_gate'] = False
        serialized = profile.json_bytes(data); record['staged_manifest_sha256'] = profile.sha(serialized)
        (self.runtime / ref.MANIFEST).write_bytes(serialized); self.save_marker(record)
        self.assertFalse(profile.verified_activation(self.runtime, self.game_dir))
        (self.runtime / ref.DLL).write_bytes(pe(9))
        with self.assertRaisesRegex(RuntimeError, 'DLL checksum'):
            profile.verified_activation(self.runtime, self.game_dir)

    def test_symlink_inputs_and_state_files_are_refused(self):
        for path in (self.game, self.artifact / 'ntdll-frame-slab.dll', self.runtime / ref.DLL,
                     self.runtime / ref.UNIX, self.runtime / ref.STATUS, self.runtime / ref.heap.STATUS):
            actual = path.with_name(path.name + '.actual'); path.rename(actual); path.symlink_to(actual.name)
            with self.assertRaisesRegex(RuntimeError, 'symlink'):
                self.stage()
            path.unlink(); actual.rename(path)
        self.stage()
        for path in (self.runtime / profile.STATUS, self.runtime / ref.MANIFEST,
                     self.runtime / self.marker()['backup'], self.runtime / self.marker()['manifest_backup']):
            actual = path.with_name(path.name + '.actual'); path.rename(actual); path.symlink_to(actual.name)
            with self.assertRaisesRegex(RuntimeError, 'symlink'):
                profile.verified_activation(self.runtime, self.game_dir)
            path.unlink(); actual.rename(path)
        self.restore()

    def test_symlink_runtime_parent_or_backups_are_refused(self):
        link = self.root / 'runtime-link'; link.symlink_to(self.runtime)
        self.args.wine = link
        with self.assertRaisesRegex(RuntimeError, 'symlink'): self.stage()
        self.args.wine = self.runtime
        elsewhere = self.root / 'backups'; elsewhere.mkdir()
        (self.runtime / profile.BACKUPS).symlink_to(elsewhere)
        with self.assertRaisesRegex(RuntimeError, 'symlink'): self.stage()
        self.assert_original()

    def test_dangling_marker_symlink_is_not_treated_as_absent(self):
        (self.runtime / profile.STATUS).symlink_to('missing')
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            profile.verified_activation(self.runtime, self.game_dir)

    def test_activation_refuses_an_update_in_progress(self):
        self.stage()
        for name in profile.RUNTIME_LOCKS:
            path = self.runtime / name; path.write_text('another updater')
            with self.assertRaisesRegex(RuntimeError, 'update in progress'):
                profile.verified_activation(self.runtime, self.game_dir)
            path.unlink()

    def test_dll_or_marker_mutation_during_verification_is_rejected(self):
        self.stage(); real_check = profile.game_identity
        for target in (self.runtime / ref.DLL, self.runtime / profile.STATUS):
            original = target.read_bytes()
            def mutate(game):
                result = real_check(game); target.write_bytes(original + b'\n'); return result
            with patch.object(profile, 'game_identity', side_effect=mutate):
                with self.assertRaisesRegex(RuntimeError, 'changed during verification'):
                    profile.verified_activation(self.runtime, self.game_dir)
            target.write_bytes(original)
        self.restore()

    def test_game_mutation_after_hash_is_rejected(self):
        self.stage(); real_check = profile.game_identity
        def mutate(game):
            result = real_check(game); self.game.write_bytes(b'replaced game'); return result
        with patch.object(profile, 'game_identity', side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, 'Minecraft executable changed'):
                profile.verified_activation(self.runtime, self.game_dir)

    def test_new_update_lock_after_snapshot_is_rejected(self):
        self.stage(); real_check = profile.game_identity; lock = self.runtime / profile.RUNTIME_LOCKS[0]
        def mutate(game):
            result = real_check(game); lock.write_text('updater'); return result
        with patch.object(profile, 'game_identity', side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, 'update in progress'):
                profile.verified_activation(self.runtime, self.game_dir)
        lock.unlink(); self.restore()


if __name__ == '__main__':
    unittest.main()
