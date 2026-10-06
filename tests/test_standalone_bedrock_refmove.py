"""Safety/recovery tests against temporary fake runtimes; never launch Wine."""
import argparse
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bedrock_refmove', ROOT / 'standalone-bedrock-refmove.py')
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


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


class RefmoveStageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.runtime, self.out = root / 'runtime', root / 'artifact'
        game_dir = root / 'game';game_dir.mkdir()
        self.game = game_dir / 'Minecraft.Windows.exe'
        self.game.write_bytes(b'fake version-pinned game executable')
        self.args = argparse.Namespace(wine=self.runtime, enable=False)
        self.original, self.candidate = pe(1), pe(2)
        base, candidate = ref.sha(self.original), ref.sha(self.candidate)
        self.inputs = {'dlls/ntdll/heap.c': ref.HEAP_SHA}
        source_sha = ref.sha(ref.json_bytes(self.inputs))
        self.addCleanup(patch.stopall)
        patch.object(ref, 'OUT', self.out).start()
        patch.object(ref, 'BASE_DLL_SHA', base).start()
        patch.object(ref, 'TESTED_DLL_SHA', candidate).start()
        patch.object(ref, 'SOURCE_INPUTS_SHA', source_sha).start()
        patch.object(ref, 'GAME_SHA', ref.sha(self.game.read_bytes())).start()
        heap_profile = {'dll_sha256': base, 'heap_source_sha256': ref.HEAP_SHA,
                        'source_commit': ref.COMMIT, 'patch_sha256': ref.HEAP_PATCH_SHA}
        self.heap_marker = ref.json_bytes(heap_profile)
        self.metadata = ref.json_bytes({'wine_source_revision': ref.COMMIT, 'wine_version': '11.8',
            'architecture': 'x86_64', 'local_modifications': {'heap_reuse': heap_profile},
            'unrelated': {'preserve': True}})
        ref.write(self.runtime / ref.DLL, self.original, 0o755)
        ref.write(self.runtime / ref.UNIX, b'unchanged Unix module')
        ref.write(self.runtime / ref.MANIFEST, self.metadata, 0o640)
        ref.write(self.runtime / ref.heap.STATUS, self.heap_marker)
        artifact = {'format': 1, 'profile': ref.PROFILE, 'source_commit': ref.COMMIT,
            'heap_source_sha256': ref.HEAP_SHA, 'source_inputs_sha256': source_sha,
            'dll_sha256': candidate, 'patch_sha256': ref.PATCH_SHA,
            'heap_patch_sha256': ref.sha(ref.heap.PATCH.read_bytes()), 'game_sha256': ref.GAME_SHA,
            'architecture': 'x86_64', 'wine_version': '11.8', 'environment': ref.ENVIRONMENT,
            'default_enabled': False}
        ref.write(self.out / 'ntdll.dll', self.candidate)
        ref.write(self.out / 'manifest.json', ref.json_bytes(artifact))
        ref.write(self.out / 'source-inputs.json', ref.json_bytes(self.inputs))
        self.lsof = patch.object(ref.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')).start()

    def assert_original(self):
        self.assertEqual((self.runtime / ref.DLL).read_bytes(), self.original)
        self.assertEqual((self.runtime / ref.MANIFEST).read_bytes(), self.metadata)
        self.assertEqual((self.runtime / ref.heap.STATUS).read_bytes(), self.heap_marker)

    def marker(self):
        return json.loads((self.runtime / ref.STATUS).read_bytes())

    def test_default_off_idempotence_and_exact_restore(self):
        ref.stage(self.args)
        marker = (self.runtime / ref.STATUS).read_bytes()
        self.assertFalse(self.marker()['requested_gate'])
        self.assertEqual(self.marker()['phase'], 'staged')
        self.assertEqual(self.marker()['environment'], ref.ENVIRONMENT)
        self.assertEqual(self.marker()['game_sha256'], ref.GAME_SHA)
        self.assertEqual((self.runtime / ref.UNIX).read_bytes(), b'unchanged Unix module')
        ref.stage(self.args)
        self.assertEqual((self.runtime / ref.STATUS).read_bytes(), marker)
        ref.stage(self.args, restore=True)
        self.assert_original()
        self.assertFalse((self.runtime / ref.STATUS).exists())
        self.assertEqual((self.runtime / ref.DLL).stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.runtime / ref.MANIFEST).stat().st_mode & 0o777, 0o640)

    def test_enable_is_an_explicit_marker_request(self):
        self.args.enable = True
        ref.stage(self.args)
        self.assertTrue(self.marker()['requested_gate'])
        self.args.enable = False
        with self.assertRaisesRegex(RuntimeError, 'Existing or partial'):
            ref.stage(self.args)

    def test_active_runtime_refused(self):
        self.lsof.return_value = subprocess.CompletedProcess([], 0, 'p123\nn/module\n', '')
        with self.assertRaisesRegex(RuntimeError, 'Close applications'):
            ref.stage(self.args)
        self.assert_original()
        self.assertIn(str(self.runtime / ref.UNIX), self.lsof.call_args.args[0])

    def test_unknown_idle_state_refused(self):
        self.lsof.return_value = subprocess.CompletedProcess([], 1, '', 'warning')
        with self.assertRaisesRegex(RuntimeError, 'whether.*idle'):
            ref.stage(self.args)
        self.assert_original()

    def test_shared_heap_lock_refused_and_preserved(self):
        lock = self.runtime / '.wine-heap-reuse.lock'
        lock.write_text('another owner')
        with self.assertRaises(FileExistsError): ref.stage(self.args)
        self.assertEqual(lock.read_text(), 'another owner')
        self.assert_original()

    def test_second_lock_failure_releases_only_own_first_lock(self):
        lock = self.runtime / '.bedrock-refmove.lock'
        lock.write_text('another owner')
        with self.assertRaises(FileExistsError): ref.stage(self.args)
        self.assertEqual(lock.read_text(), 'another owner')
        self.assertFalse((self.runtime / '.wine-heap-reuse.lock').exists())

    def test_unsupported_runtime_refused(self):
        value = json.loads(self.metadata);value['wine_source_revision'] = 'unknown'
        ref.write(self.runtime / ref.MANIFEST, ref.json_bytes(value))
        with self.assertRaisesRegex(RuntimeError, 'pinned'): ref.stage(self.args)

    def test_unknown_dll_profile_refused(self):
        ref.write(self.runtime / ref.DLL, pe(3))
        with self.assertRaisesRegex(RuntimeError, 'overlapping profile'): ref.stage(self.args)

    def test_untracked_candidate_refused(self):
        ref.write(self.runtime / ref.DLL, self.candidate)
        with self.assertRaisesRegex(RuntimeError, 'overlapping profile'): ref.stage(self.args)

    def test_mismatched_heap_marker_refused(self):
        value = json.loads(self.heap_marker);value['dll_sha256'] = 'unknown'
        ref.write(self.runtime / ref.heap.STATUS, ref.json_bytes(value))
        with self.assertRaisesRegex(RuntimeError, 'mismatched heap'): ref.stage(self.args)

    def test_changed_dll_not_overwritten_on_restore(self):
        ref.stage(self.args);ref.write(self.runtime / ref.DLL, pe(3))
        with self.assertRaisesRegex(RuntimeError, 'DLL changed'): ref.stage(self.args, restore=True)

    def test_changed_runtime_manifest_not_overwritten(self):
        ref.stage(self.args)
        target = self.runtime / ref.MANIFEST;target.write_bytes(target.read_bytes() + b'\n')
        with self.assertRaisesRegex(RuntimeError, 'manifest changed'): ref.stage(self.args, restore=True)

    def test_changed_heap_marker_not_overwritten(self):
        ref.stage(self.args)
        (self.runtime / ref.heap.STATUS).write_bytes(self.heap_marker + b'\n')
        with self.assertRaisesRegex(RuntimeError, 'Heap profile marker changed'): ref.stage(self.args, restore=True)

    def test_partial_write_failure_has_recoverable_journal(self):
        original_write = ref.write
        def fail_metadata(path, data, mode=0o644):
            if path == self.runtime / ref.MANIFEST: raise OSError('injected write failure')
            original_write(path, data, mode)
        with patch.object(ref, 'write', side_effect=fail_metadata):
            with self.assertRaisesRegex(OSError, 'injected'): ref.stage(self.args)
        self.assertEqual(self.marker()['phase'], 'prepared')
        self.assertEqual((self.runtime / ref.DLL).read_bytes(), self.candidate)
        ref.stage(self.args, restore=True)
        self.assert_original()

    def test_restore_after_runtime_files_already_recovered(self):
        ref.stage(self.args)
        ref.write(self.runtime / ref.DLL, self.original)
        ref.write(self.runtime / ref.MANIFEST, self.metadata)
        ref.stage(self.args, restore=True)
        self.assert_original()

    def test_restore_does_not_depend_on_candidate_artifact(self):
        ref.stage(self.args);(self.out / 'ntdll.dll').unlink()
        ref.stage(self.args, restore=True)
        self.assert_original()

    def test_corrupt_backup_refused(self):
        ref.stage(self.args)
        (self.runtime / self.marker()['backup']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(RuntimeError, 'Backup checksum'): ref.stage(self.args, restore=True)

    def test_repeat_stage_checks_recoverability(self):
        ref.stage(self.args)
        (self.runtime / self.marker()['manifest_backup']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(RuntimeError, 'Backup checksum'): ref.stage(self.args)

    def test_marker_identity_fields_cannot_be_substituted(self):
        ref.stage(self.args)
        original = self.marker()
        for key, value in (('environment', 'OTHER_GATE'), ('game_sha256', 'unknown'),
                           ('requested_gate', 1), ('previous_marker_present', True)):
            with self.subTest(key=key):
                altered = dict(original);altered[key] = value
                ref.write(self.runtime / ref.STATUS, ref.json_bytes(altered))
                with self.assertRaisesRegex(RuntimeError, 'staging marker'):
                    ref.stage(self.args, restore=True)
                with self.assertRaisesRegex(RuntimeError, 'staging marker'):
                    ref.stage(self.args)

    def test_escape_in_marker_refused(self):
        ref.stage(self.args);value = self.marker();value['backup'] = '../elsewhere'
        ref.write(self.runtime / ref.STATUS, ref.json_bytes(value))
        with self.assertRaisesRegex(RuntimeError, 'escaping'): ref.stage(self.args, restore=True)

    def test_symlink_module_refused(self):
        target = self.runtime / ref.DLL;other = target.with_name('other.dll')
        target.rename(other);target.symlink_to(other.name)
        with self.assertRaisesRegex(RuntimeError, 'symlink'): ref.stage(self.args)

    def test_symlink_parent_refused(self):
        parent = (self.runtime / ref.DLL).parent;real = parent.with_name('real-pe')
        parent.rename(real);parent.symlink_to(real.name)
        with self.assertRaisesRegex(RuntimeError, 'symlink'): ref.stage(self.args)

    def test_symlink_runtime_root_refused(self):
        link = self.runtime.with_name('runtime-link');link.symlink_to(self.runtime)
        self.args.wine = link
        with self.assertRaisesRegex(RuntimeError, 'symlink'): ref.stage(self.args)

    def test_symlink_artifact_parent_refused(self):
        actual_parent = self.out.with_name('real-artifacts');actual_parent.mkdir()
        moved = actual_parent / self.out.name;self.out.rename(moved)
        link = actual_parent.with_name('linked-artifacts');link.symlink_to(actual_parent)
        ref.OUT = link / self.out.name
        with self.assertRaisesRegex(RuntimeError, 'symlink'): ref.stage(self.args)
        self.assert_original()

    def test_symlink_backups_refused(self):
        elsewhere = self.runtime.with_name('elsewhere');elsewhere.mkdir()
        (self.runtime / ref.BACKUPS).symlink_to(elsewhere)
        with self.assertRaisesRegex(RuntimeError, 'symlink'): ref.stage(self.args)
        self.assert_original()

    def test_artifact_bytes_and_source_record_are_verified(self):
        (self.out / 'ntdll.dll').write_bytes(pe(3))
        with self.assertRaisesRegex(RuntimeError, 'byte/hash/source'): ref.stage(self.args)
        (self.out / 'ntdll.dll').write_bytes(self.candidate)
        ref.write(self.out / 'source-inputs.json', ref.json_bytes({'dlls/ntdll/heap.c': 'changed'}))
        with self.assertRaisesRegex(RuntimeError, 'byte/hash/source'): ref.stage(self.args)
        self.assert_original()

    def test_patch_and_default_gate_provenance_verified(self):
        artifact = json.loads((self.out / 'manifest.json').read_bytes());artifact['default_enabled'] = True
        ref.write(self.out / 'manifest.json', ref.json_bytes(artifact))
        with self.assertRaisesRegex(RuntimeError, 'byte/hash/source'): ref.stage(self.args)
        self.assert_original()

    def test_activation_absent_marker_is_false_without_artifact_dependency(self):
        (self.out / 'ntdll.dll').unlink()
        self.assertIs(ref.verified_activation(self.runtime), False)

    def test_activation_verifies_both_off_and_on_without_reading_game_by_default(self):
        ref.stage(self.args)
        self.assertIs(ref.verified_activation(self.runtime), False)
        ref.stage(self.args, restore=True)
        self.args.enable = True;ref.stage(self.args)
        (self.out / 'ntdll.dll').unlink();self.game.unlink()
        self.assertIs(ref.verified_activation(self.runtime), True)
        self.lsof.reset_mock()
        ref.verified_activation(self.runtime)
        self.lsof.assert_not_called()

    def test_activation_off_does_not_hide_corrupt_dll(self):
        ref.stage(self.args);ref.write(self.runtime / ref.DLL, pe(3))
        with self.assertRaisesRegex(RuntimeError, 'DLL checksum'):
            ref.verified_activation(self.runtime)

    def test_activation_checks_optional_full_game_hash(self):
        self.args.enable = True;ref.stage(self.args)
        self.assertIs(ref.verified_activation(self.runtime, self.game.parent), True)
        self.game.write_bytes(b'unsupported changed game')
        with self.assertRaisesRegex(RuntimeError, 'Unsupported Minecraft'):
            ref.verified_activation(self.runtime, self.game.parent)

    def test_activation_rejects_partial_profile(self):
        ref.stage(self.args);record = self.marker();record['phase'] = 'prepared'
        ref.write(self.runtime / ref.STATUS, ref.json_bytes(record))
        with self.assertRaisesRegex(RuntimeError, 'Partial'):
            ref.verified_activation(self.runtime)

    def test_activation_rejects_manifest_or_heap_marker_hash_drift(self):
        ref.stage(self.args)
        for name, error in ((ref.MANIFEST, 'manifest checksum'), (ref.heap.STATUS, 'heap marker checksum')):
            with self.subTest(name=name):
                target = self.runtime / name;original = target.read_bytes()
                target.write_bytes(original + b'\n')
                with self.assertRaisesRegex(RuntimeError, error): ref.verified_activation(self.runtime)
                target.write_bytes(original)

    def test_activation_checks_source_identity_independently_of_manifest_hash(self):
        ref.stage(self.args)
        original = (self.runtime / ref.MANIFEST).read_bytes()
        record = self.marker()
        for key in ('source_commit', 'heap_source_sha256', 'source_inputs_sha256',
                    'patch_sha256', 'heap_patch_sha256', 'game_sha256', 'environment'):
            with self.subTest(key=key):
                metadata = json.loads(original)
                metadata['local_modifications']['bedrock_refmove'][key] = 'unknown'
                data = ref.json_bytes(metadata);ref.write(self.runtime / ref.MANIFEST, data)
                altered = dict(record, staged_manifest_sha256=ref.sha(data))
                ref.write(self.runtime / ref.STATUS, ref.json_bytes(altered))
                with self.assertRaisesRegex(RuntimeError, 'source or gate identity'):
                    ref.verified_activation(self.runtime)

    def test_activation_checks_heap_source_identity_independently_of_marker_hash(self):
        ref.stage(self.args)
        heap_marker = json.loads(self.heap_marker);heap_marker['patch_sha256'] = 'unknown'
        data = ref.json_bytes(heap_marker);ref.write(self.runtime / ref.heap.STATUS, data)
        record = self.marker();record['heap_marker_sha256'] = ref.sha(data)
        ref.write(self.runtime / ref.STATUS, ref.json_bytes(record))
        with self.assertRaisesRegex(RuntimeError, 'heap source patch'):
            ref.verified_activation(self.runtime)

    def test_activation_rejects_symlink_state_files_and_optional_game(self):
        ref.stage(self.args)
        for target in (self.runtime / ref.STATUS, self.runtime / ref.MANIFEST,
                       self.runtime / ref.heap.STATUS, self.runtime / ref.DLL,
                       self.runtime / self.marker()['backup'], self.game):
            with self.subTest(target=target.name):
                real = target.with_name(target.name + '.actual');target.rename(real)
                target.symlink_to(real.name)
                with self.assertRaisesRegex(RuntimeError, 'symlink'):
                    ref.verified_activation(self.runtime, self.game.parent)
                target.unlink();real.rename(target)

    def test_activation_rejects_active_profile_update(self):
        ref.stage(self.args)
        for name in ('.wine-heap-reuse.lock', '.bedrock-refmove.lock'):
            lock = self.runtime / name;lock.write_text('updater')
            with self.assertRaisesRegex(RuntimeError, 'update in progress'):
                ref.verified_activation(self.runtime)
            lock.unlink()

    def test_activation_rejects_state_changed_during_verification(self):
        ref.stage(self.args)
        original_check = ref.check_runtime
        def change_marker(runtime):
            result = original_check(runtime)
            record = self.marker();record['phase'] = 'prepared'
            ref.write(runtime / ref.STATUS, ref.json_bytes(record))
            return result
        with patch.object(ref, 'check_runtime', side_effect=change_marker):
            with self.assertRaisesRegex(RuntimeError, 'changed during'):
                ref.verified_activation(self.runtime)

    def test_activation_reports_malformed_marker_as_runtime_error(self):
        ref.stage(self.args)
        for data in (b'{', b'[]', b'null'):
            ref.write(self.runtime / ref.STATUS, data)
            with self.assertRaises(RuntimeError): ref.verified_activation(self.runtime)


if __name__ == '__main__':
    unittest.main()
