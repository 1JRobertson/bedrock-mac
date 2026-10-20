"""Picker installation fixtures never start Wine or touch real app data."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pickers', Path(__file__).resolve().parents[1] / 'standalone-pickers.py')
pickers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pickers)


def pe():
    data = bytearray(256)
    data[:2], data[60:64], data[128:134] = b'MZ', (128).to_bytes(4, 'little'), b'PE\0\0\x64\x86'
    return bytes(data)


class PickerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.wine, self.prefix = (self.root / name for name in ('source', 'wine', 'prefix'))
        self.prefix.mkdir()
        for name in pickers.SOURCE_INPUTS:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('frozen source ' + name)
        self.dll = self.wine / 'lib/wine/x86_64-windows/bedrock-pickers.dll'
        self.dll.parent.mkdir(parents=True)
        self.dll.write_bytes(pe())
        self.build_receipt()
        self.addCleanup(patch.stopall)
        patch.object(pickers, 'source_root', return_value=self.source).start()

    def build_receipt(self):
        data = {'version': 1, 'files': {'bedrock-pickers.dll': pickers.digest(self.dll)},
                'source_sha256': {name: pickers.digest(self.source / name) for name in pickers.SOURCE_INPUTS}}
        (self.wine / 'file-pickers-build.json').write_text(json.dumps(data))

    def registry(self, mappings):
        text = 'WINE REGISTRY Version 2\n'
        for name, path in mappings.items():
            text += '[' + (pickers.KEY + '\\' + name).replace('\\', '\\\\') + '] 123\n'
            if path is not None:
                text += '"DllPath"="' + path.replace('\\', '\\\\') + '"\n'
        (self.prefix / 'system.reg').write_text(text)

    def register(self, path):
        text = path.read_text(encoding='utf-16')
        self.assertEqual(text.count('"ThreadingModel"=dword:00000000'), 4)
        for name in pickers.CLASSES:
            self.assertIn(name, text)
        self.registry({name: pickers.DLL for name in pickers.CLASSES})

    def snapshot(self):
        return {str(p.relative_to(self.prefix)): p.read_bytes() for p in self.prefix.rglob('*') if p.is_file()}

    def test_fresh_install_registers_four_classes_and_exact_dll(self):
        pickers.install(self.prefix, self.wine, self.register)
        self.assertEqual((self.prefix / 'drive_c/windows/system32/bedrock-pickers.dll').read_bytes(), pe())
        self.assertTrue(pickers.installed(self.prefix, self.wine))
        record = json.loads((self.prefix / pickers.RECEIPT).read_text())
        self.assertEqual(record['phase'], 'installed')
        self.assertTrue((self.prefix / record['backup']).is_dir())

    def test_source_and_dll_changes_fail_before_prefix_mutation(self):
        for path in (self.source / 'file-pickers/pickers.c', self.dll):
            original = path.read_bytes()
            path.write_bytes(b'changed source or dll')
            before = self.snapshot()
            with self.subTest(path=path), self.assertRaisesRegex(RuntimeError, 'verification'):
                pickers.install(self.prefix, self.wine, self.register)
            self.assertEqual(self.snapshot(), before)
            path.write_bytes(original)

    def test_non_x64_dll_is_rejected_even_with_matching_receipt(self):
        self.dll.write_bytes(b'MZ' + bytes(254))
        self.build_receipt()
        with self.assertRaisesRegex(RuntimeError, 'verification'):
            pickers.verify_runtime(self.wine)

    def test_documentation_and_contract_edits_do_not_invalidate_runtime(self):
        for name in ('file-pickers/README.md', 'file-pickers/check-windows.cmd',
                     'tests/file-picker-contract.c'):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('original documentation or test source')
        self.build_receipt()
        expected = pickers.verify_runtime(self.wine)
        for name in ('file-pickers/README.md', 'file-pickers/check-windows.cmd',
                     'tests/file-picker-contract.c'):
            (self.source / name).write_text('updated documentation or contract test')
            with self.subTest(path=name):
                self.assertEqual(pickers.verify_runtime(self.wine), expected)

    def test_packaged_verification_uses_bundled_provenance(self):
        # The verification API accepts shipped scripts, without sources/ or a checkout.
        self.assertEqual(pickers.verify_runtime(self.wine, self.source)['dll_sha256'], pickers.digest(self.dll))
        (self.source / pickers.SOURCE_INPUTS[0]).unlink()
        with self.assertRaisesRegex(RuntimeError, 'verification'):
            pickers.verify_runtime(self.wine, self.source)

    def test_unknown_registration_preserves_every_prefix_byte(self):
        for path in (r'C:\custom\picker.dll', pickers.DLL, None):
            self.registry({pickers.CLASSES[0]: path})
            before = self.snapshot()
            with self.subTest(path=path), self.assertRaisesRegex(RuntimeError, 'registration must be preserved'):
                pickers.install(self.prefix, self.wine, self.register)
            self.assertEqual(self.snapshot(), before)

    def test_existing_builtin_storage_file_can_be_replaced_with_backup(self):
        self.registry({'Windows.Storage.StorageFile': r'C:\windows\system32\windows.storage.dll'})
        builtin = self.prefix / 'drive_c/windows/system32/windows.storage.dll'
        builtin.parent.mkdir(parents=True)
        builtin.write_bytes(b'MZ Wine builtin DLL')
        original = (self.prefix / 'system.reg').read_bytes()
        pickers.install(self.prefix, self.wine, self.register)
        receipt = json.loads((self.prefix / pickers.RECEIPT).read_text())
        self.assertEqual((self.prefix / receipt['backup'] / 'system.reg').read_bytes(), original)
        self.assertEqual(builtin.read_bytes(), b'MZ Wine builtin DLL')

    def test_custom_storage_dll_is_preserved(self):
        self.registry({'Windows.Storage.StorageFile': r'C:\windows\system32\windows.storage.dll'})
        builtin = self.prefix / 'drive_c/windows/system32/windows.storage.dll'
        builtin.parent.mkdir(parents=True)
        builtin.write_bytes(b'custom provider')
        before = self.snapshot()
        with self.assertRaisesRegex(RuntimeError, 'not a recognized Wine builtin'):
            pickers.install(self.prefix, self.wine, self.register)
        self.assertEqual(self.snapshot(), before)

    def test_upgrade_preserves_previous_bridge_bytes_and_receipt(self):
        pickers.install(self.prefix, self.wine, self.register)
        old_receipt = (self.prefix / pickers.RECEIPT).read_bytes()
        self.dll.write_bytes(pe() + b'new bridge')
        self.build_receipt()
        pickers.install(self.prefix, self.wine, self.register)
        record = json.loads((self.prefix / pickers.RECEIPT).read_text())
        self.assertEqual((self.prefix / record['backup'] / 'bedrock-pickers.dll').read_bytes(), pe())
        self.assertEqual((self.prefix / record['backup'] / 'receipt.json').read_bytes(), old_receipt)
        self.assertTrue(pickers.installed(self.prefix, self.wine))

    def test_unknown_existing_bridge_file_is_never_overwritten(self):
        target = self.prefix / 'drive_c/windows/system32/bedrock-pickers.dll'
        target.parent.mkdir(parents=True)
        target.write_bytes(b'unknown bridge')
        with self.assertRaisesRegex(RuntimeError, 'unrecognized picker DLL'):
            pickers.install(self.prefix, self.wine, self.register)
        self.assertEqual(target.read_bytes(), b'unknown bridge')

    def test_failed_registration_retains_recovery_bytes_and_can_retry(self):
        def fail(_path):
            self.registry({pickers.CLASSES[0]: pickers.DLL})
            raise RuntimeError('fixture reg failure')
        with self.assertRaisesRegex(RuntimeError, 'fixture reg failure'):
            pickers.install(self.prefix, self.wine, fail)
        self.assertFalse(pickers.installed(self.prefix, self.wine))
        record = json.loads((self.prefix / pickers.RECEIPT).read_text())
        self.assertEqual(record['phase'], 'installing')
        self.assertTrue((self.prefix / record['backup']).is_dir())
        pickers.install(self.prefix, self.wine, self.register)
        self.assertTrue(pickers.installed(self.prefix, self.wine))

    def test_symlinked_prefix_components_are_rejected(self):
        outside = self.root / 'other-prefix'
        outside.mkdir()
        (self.prefix / 'drive_c').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'installation link'):
            pickers.install(self.prefix, self.wine, self.register)
        self.assertEqual(list(outside.iterdir()), [])

    def test_interrupted_dll_replace_preserves_old_dll(self):
        pickers.install(self.prefix, self.wine, self.register)
        target = self.prefix / 'drive_c/windows/system32/bedrock-pickers.dll'
        self.dll.write_bytes(pe() + b'update')
        self.build_receipt()
        original_replace = os.replace
        def fail(source, destination):
            if destination == target:
                raise OSError('fixture disk failure')
            return original_replace(source, destination)
        with patch.object(pickers.os, 'replace', side_effect=fail), self.assertRaises(OSError):
            pickers.install(self.prefix, self.wine, self.register)
        self.assertEqual(target.read_bytes(), pe())
        pickers.install(self.prefix, self.wine, self.register)
        self.assertTrue(pickers.installed(self.prefix, self.wine))
