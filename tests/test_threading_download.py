"""The reduced official download must retain the original verification boundary."""
import importlib.util
import io
import zipfile
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('setup', Path(__file__).resolve().parents[1] / 'standalone-setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ReducedDownloadTests(unittest.TestCase):
    def test_server_ignoring_range_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(setup.subprocess, 'check_output', return_value='200'), \
                patch.object(setup, 'threading_from_bundle') as extract:
            with self.assertRaisesRegex(RuntimeError, 'failed verification'):
                setup.download_threading_member(Path(folder))
            extract.assert_not_called()

    def test_changed_range_bytes_are_rejected_before_decompression(self):
        def response(command, **kwargs):
            Path(command[command.index('--output') + 1]).write_bytes(b'bad')
            return '206'
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(setup.subprocess, 'check_output', side_effect=response), \
                patch.object(setup, 'GAMING_SIZE', 3), \
                patch.object(setup.zlib, 'decompress') as decompress:
            with self.assertRaisesRegex(RuntimeError, 'failed verification'):
                setup.download_threading_member(Path(folder))
            decompress.assert_not_called()

    def test_truncated_or_oversized_range_never_reaches_decompression(self):
        for payload in (b'x', b'xxxx'):
            def response(command, **kwargs):
                self.assertEqual(command[command.index('--proto') + 1], '=https')
                self.assertEqual(command[command.index('--proto-redir') + 1], '=https')
                Path(command[command.index('--output') + 1]).write_bytes(payload)
                return '206'
            with tempfile.TemporaryDirectory() as folder, \
                    patch.object(setup.subprocess, 'check_output', side_effect=response), \
                    patch.object(setup, 'GAMING_SIZE', 3), \
                    patch.object(setup.zlib, 'decompress') as decompress:
                with self.assertRaisesRegex(RuntimeError, 'failed verification'):
                    setup.download_threading_member(Path(folder))
                decompress.assert_not_called()

    def test_changed_final_dll_is_rejected(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as appx:
            appx.writestr('xgameruntime.dll', b'tampered fixture')
        outer = io.BytesIO()
        with zipfile.ZipFile(outer, 'w') as bundle:
            bundle.writestr('GamingServicesTcui-Package_35.116.29001.0_x64.appx', inner.getvalue())
        with self.assertRaisesRegex(RuntimeError, 'checksum validation'):
            setup.threading_from_bundle(outer.getvalue())


if __name__ == '__main__':
    unittest.main()
