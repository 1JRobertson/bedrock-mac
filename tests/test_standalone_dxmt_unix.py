"""Transaction tests run without Wine, a GPU, or downloaded artifacts."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('dxmt_unix', Path(__file__).resolve().parent.parent / 'standalone-dxmt-unix.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / 'output'; self.output.mkdir()
        self.runtime = self.root / 'wine'; (self.runtime / 'bin').mkdir(parents=True)
        (self.runtime / 'bin/wine').write_bytes(b'wine fixture')
        self.lib = self.runtime / 'lib/wine/x86_64-unix'; self.lib.mkdir(parents=True)
        (self.output / 'winemetal.so').write_bytes(b'new bridge')
        (self.output / 'winemetal-upstream.so').write_bytes(b'original library')
        (self.lib / 'winemetal.so').write_bytes(b'original library')
        self.upstream_sha = hashlib.sha256(b'original library').hexdigest()
        self.metadata = {'files': {name: bridge.digest(self.output / name) for name in bridge.FILES}}
        for patch in (mock.patch.object(bridge, 'OUTPUT', self.output),
                      mock.patch.object(bridge, 'UPSTREAM_SHA', self.upstream_sha),
                      mock.patch.object(bridge, 'verified_output', return_value=self.metadata),
                      mock.patch.object(bridge, 'refuse_mapped')):
            patch.start(); self.addCleanup(patch.stop)

    def test_stage_preserves_original(self):
        bridge.stage(self.runtime)
        metadata = json.loads((self.runtime / 'dxmt-unix-bridge.json').read_text())
        self.assertEqual((self.runtime / metadata['original_backup']).read_bytes(), b'original library')
        for name in bridge.FILES:
            self.assertEqual(bridge.digest(self.lib / name), metadata['files'][name])

    def test_failed_manifest_commit_restores_missing_files(self):
        replace = bridge.os.replace
        def fail_manifest(source, target):
            if Path(target).name == 'dxmt-unix-bridge.json': raise OSError('injected commit failure')
            return replace(source, target)
        with mock.patch.object(bridge.os, 'replace', side_effect=fail_manifest):
            with self.assertRaisesRegex(OSError, 'injected'):
                bridge.stage(self.runtime)
        self.assertEqual((self.lib / 'winemetal.so').read_bytes(), b'original library')
        self.assertFalse((self.lib / 'winemetal-upstream.so').exists())
        self.assertFalse((self.runtime / 'dxmt-unix-bridge.json').exists())
        self.assertFalse(list(self.runtime.glob('.dxmt-stage-*')))

    def test_failed_post_install_check_restores_previous_pair_and_manifest(self):
        (self.lib / 'winemetal.so').write_bytes(b'old bridge')
        (self.lib / 'winemetal-upstream.so').write_bytes(b'original library')
        manifest = self.runtime / 'dxmt-unix-bridge.json'
        previous = json.dumps({'files': {'winemetal.so': bridge.digest(self.lib / 'winemetal.so')}})
        manifest.write_text(previous)
        digest = bridge.digest
        def fail_installed(path):
            if Path(path).resolve() == (self.lib / 'winemetal.so').resolve() and Path(path).read_bytes() == b'new bridge':
                return 'injected mismatch'
            return digest(path)
        with mock.patch.object(bridge, 'digest', side_effect=fail_installed):
            with self.assertRaisesRegex(RuntimeError, 'Installed artifact'):
                bridge.stage(self.runtime)
        self.assertEqual((self.lib / 'winemetal.so').read_bytes(), b'old bridge')
        self.assertEqual((self.lib / 'winemetal-upstream.so').read_bytes(), b'original library')
        self.assertEqual(manifest.read_text(), previous)

    def test_mapped_target_is_rejected_before_writes(self):
        bridge.refuse_mapped.side_effect = RuntimeError('mapped target')
        with self.assertRaisesRegex(RuntimeError, 'mapped target'):
            bridge.stage(self.runtime)
        self.assertEqual((self.lib / 'winemetal.so').read_bytes(), b'original library')
        self.assertFalse((self.runtime / 'dxmt-unix-bridge-backups').exists())


if __name__ == '__main__':
    unittest.main()
