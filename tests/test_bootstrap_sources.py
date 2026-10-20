"""Check that source preparation preserves user checkouts and rejects unsafe patches."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location("bootstrap_sources", Path(__file__).resolve().parents[1] / "bootstrap-sources.py")
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_all_helper_inputs_are_copied_and_destination_links_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            project, destination = root / "project", root / "xodus"
            destination.mkdir()
            for source_name in bootstrap.HELPER_INPUTS:
                source = project / source_name
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(source_name.encode())
            bootstrap.copy_helper_inputs(destination, project)
            for source_name, target in bootstrap.HELPER_INPUTS.items():
                self.assertEqual((destination / target).read_bytes(), source_name.encode())
            target = destination / bootstrap.HELPER_INPUTS["LICENSES/XVD-GreenGamesPublicKey.rsa"]
            target.unlink()
            outside = root / "preserved"
            outside.write_bytes(b"preserved")
            target.symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "Symlink helper source input"):
                bootstrap.copy_helper_inputs(destination, project)
            self.assertEqual(outside.read_bytes(), b"preserved")

    def test_existing_checkouts_are_rejected_before_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "xodus"
            source.mkdir()
            (source / "local-change").write_text("preserve")
            with mock.patch.object(bootstrap, "run") as run:
                with self.assertRaisesRegex(ValueError, "already exists"):
                    bootstrap.bootstrap(root, ("winegdk", "xodus"))
                run.assert_not_called()
            self.assertEqual((source / "local-change").read_text(), "preserve")

    def test_unsafe_patch_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            patch = Path(temp) / "unsafe.patch"
            patch.write_text("--- a/../outside\n+++ b/../outside\n")
            with self.assertRaisesRegex(ValueError, "Unsafe patch"):
                bootstrap.patch_paths([patch])

    def test_reference_patch_paths_are_identified(self):
        with tempfile.TemporaryDirectory() as temp:
            patch = Path(temp) / "safe.patch"
            patch.write_text("--- a/src/old.c\n+++ b/src/old.c\n--- /dev/null\n+++ b/src/new.c\n")
            self.assertEqual(bootstrap.patch_paths([patch]), ["src/new.c", "src/old.c"])


if __name__ == "__main__":
    unittest.main()
