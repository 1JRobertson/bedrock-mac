"""Offline setup/restart failure checks. Never read Keychain or run a game."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


setup = module("setup_under_test", "client/standalone-setup.py")
gameinput = module("input_under_test", "client/standalone-gameinput.py")
bootstrap = module("bootstrap_under_test", "tools/bootstrap-sources.py")
native_dependencies = module("native_dependencies_under_test", "tools/build-native-dependencies.py")


class DependencyPrefixTests(unittest.TestCase):
    def test_build_environment_excludes_unrecorded_compiler_and_config_overrides(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(setup.os.environ, {
            "LIBTASN1_CFLAGS": "-I/unreviewed", "NETTLE_LIBS": "/unreviewed/static.a",
            "LIBS": "/unreviewed/object.o", "CONFIG_SITE": "/unreviewed/config.site",
            "ac_cv_header_fixture_h": "yes", "DYLD_INSERT_LIBRARIES": "/unreviewed/library",
        }):
            root = Path(temporary)
            env = native_dependencies.build_environment(root, root / "prefix", "/sdk", "/clang", "/pkg-config")
            for key in ("LIBTASN1_CFLAGS", "NETTLE_LIBS", "LIBS", "ac_cv_header_fixture_h", "DYLD_INSERT_LIBRARIES"):
                self.assertNotIn(key, env)
            self.assertEqual(env["CONFIG_SITE"], "/dev/null")
            self.assertEqual(env["ZLIB_CFLAGS"], "-I/sdk/usr/include")
            self.assertEqual(env["HOME"], str(root / "build-home"))

    def test_cached_sources_outputs_and_build_identity_are_never_reblessed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources, prefix = root / "source", root / "prefix"
            sources.mkdir()
            prefix.mkdir()
            native_dependencies.require_fresh_outputs(root, sources, prefix)
            for path in (sources / "configure", prefix / "gnutls.h", root / "build-identity.json"):
                path.write_bytes(b"edited cached build input")
                with self.assertRaisesRegex(ValueError, "not reusable"):
                    native_dependencies.require_fresh_outputs(root, sources, prefix)
                self.assertEqual(path.read_bytes(), b"edited cached build input")
                path.unlink()

    def test_changed_dependency_and_unlisted_file_fail_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("lib/libgnutls.30.dylib", "lib/libfreetype.6.dylib", "include/gnutls/gnutls.h", "include/freetype2/ft2build.h"):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"fixture")
            record = {"schema": 1, "source_built": True, "architecture": "x86_64", "lock_sha256": native_dependencies.digest(native_dependencies.LOCK), "source_archives": json.loads(native_dependencies.LOCK.read_text())["components"], "files": native_dependencies.inventory(root)}
            (root / "dependency-manifest.json").write_text(json.dumps(record))
            native_dependencies.verify(root)
            (root / "lib/libgnutls.30.dylib").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "differs from its manifest"):
                native_dependencies.verify(root)
            (root / "lib/libgnutls.30.dylib").write_bytes(b"fixture")
            (root / "lib/unreviewed.dylib").write_bytes(b"extra")
            with self.assertRaisesRegex(ValueError, "differs from its manifest"):
                native_dependencies.verify(root)

    def test_dependency_links_cannot_escape_prefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "prefix"
            root.mkdir()
            outside = Path(temporary) / "outside"
            outside.write_bytes(b"preserved")
            (root / "library").symlink_to(outside)
            with self.assertRaisesRegex(ValueError, "Unsafe dependency link"):
                native_dependencies.inventory(root)
            self.assertEqual(outside.read_bytes(), b"preserved")


class SourceVerificationTests(unittest.TestCase):
    def verify_fixture(self, directory):
        reference = {"Cargo.toml": b"fixture manifest", "src/unpatched.rs": b"trusted source"}

        def git(*args, **kwargs):
            if args[1] == "rev-parse":
                return b"fixture-commit\n"
            if args[1] == "ls-tree":
                return b"".join(b"100644 blob unused\t" + name.encode() + b"\0" for name in reference)
            if args[1] == "show":
                return reference[args[2].split(":", 1)[1]]
            raise AssertionError(args)

        def apply(root, *args):
            (root / "Cargo.lock").write_bytes(b"locked dependencies")
            for source_name, destination in bootstrap.HELPER_INPUTS.items():
                target = root / destination
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source_name.encode())

        with patch.object(bootstrap, "run", side_effect=git), patch.object(bootstrap, "apply_project", side_effect=apply):
            return bootstrap.verify_project(directory, "xodus", {"commit": "fixture-commit", "patches": ()})

    def source(self, root):
        (root / "src").mkdir()
        (root / "Cargo.toml").write_bytes(b"fixture manifest")
        (root / "src/unpatched.rs").write_bytes(b"trusted source")
        (root / "Cargo.lock").write_bytes(b"locked dependencies")
        for source_name, destination in bootstrap.HELPER_INPUTS.items():
            target = root / destination
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source_name.encode())

    def test_unpatched_source_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root)
            self.assertEqual(self.verify_fixture(root), 6)
            (root / "src/unpatched.rs").write_bytes(b"changed build input")
            with self.assertRaisesRegex(ValueError, "Source differs"):
                self.verify_fixture(root)

    def test_all_owned_helper_inputs_are_verified(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root)
            for source_name, destination in bootstrap.HELPER_INPUTS.items():
                target = root / destination
                target.write_bytes(b"tampered")
                with self.assertRaisesRegex(ValueError, "Source differs"):
                    self.verify_fixture(root)
                target.unlink()
                with self.assertRaisesRegex(ValueError, "Missing regular"):
                    self.verify_fixture(root)
                target.write_bytes(source_name.encode())

    def test_untracked_build_script_and_source_symlink_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.source(root)
            (root / "build.rs").write_text("unexpected build script")
            with self.assertRaisesRegex(ValueError, "Unexpected Xodus source input"):
                self.verify_fixture(root)
            (root / "build.rs").unlink()
            (root / "src/unpatched.rs").unlink()
            (root / "src/unpatched.rs").symlink_to(root / "Cargo.toml")
            with self.assertRaisesRegex(ValueError, "Unexpected Xodus source input"):
                self.verify_fixture(root)


class SetupRecoveryTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "macOS atomic installation promotion")
    def test_completed_partial_gdk_is_recovered_without_another_request(self):
        archive, dll = b"archive-fixture", b"dll-fixture"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "downloads").mkdir()
            partial = root / "downloads" / (setup.GDK_NAME + ".part")
            partial.write_bytes(archive)
            target = root / "runtime/threading.dll"
            with patch.multiple(setup, ROOT=root, THREADING=target, GDK_SIZE=len(archive),
                                GDK_SHA256=hashlib.sha256(archive).hexdigest()), \
                 patch.object(setup, "extract_threading", return_value=dll), \
                 patch.object(setup.subprocess, "run", side_effect=AssertionError("Unexpected network request")), redirect_stdout(io.StringIO()):
                setup.acquire_threading()
            self.assertEqual(target.read_bytes(), dll)
            self.assertFalse(partial.exists())
            self.assertEqual((root / "downloads" / setup.GDK_NAME).read_bytes(), archive)

    def test_conflicting_complete_partial_is_preserved_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "downloads").mkdir()
            partial = root / "downloads" / (setup.GDK_NAME + ".part")
            partial.write_bytes(b"wrong")
            with patch.multiple(setup, ROOT=root, THREADING=root / "runtime/dll", GDK_SIZE=5), \
                 patch.object(setup.subprocess, "run", side_effect=AssertionError("Unexpected network request")):
                with self.assertRaises(RuntimeError):
                    setup.acquire_threading()
            self.assertEqual(partial.read_bytes(), b"wrong")

    def test_partial_download_symlink_cannot_redirect_curl(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "downloads").mkdir()
            original = root / "preserve"
            original.write_bytes(b"preserve")
            (root / "downloads" / (setup.GDK_NAME + ".part")).symlink_to(original)
            with patch.multiple(setup, ROOT=root, THREADING=root / "runtime/dll"), \
                 patch.object(setup.subprocess, "run", side_effect=AssertionError("Unexpected network request")):
                with self.assertRaises(RuntimeError):
                    setup.acquire_threading()
            self.assertEqual(original.read_bytes(), b"preserve")

    def test_failed_clone_does_not_poison_the_final_source_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            final = root / "sources/xodus"

            def interrupted_clone(command, **unused):
                Path(command[-1]).mkdir()
                (Path(command[-1]) / "partial").write_bytes(b"incomplete")
                raise subprocess.CalledProcessError(128, ["git", "clone"])

            with patch.multiple(setup, ROOT=root, XODUS=final), patch.object(setup.subprocess, "run", side_effect=interrupted_clone):
                with self.assertRaises(subprocess.CalledProcessError):
                    setup.prepare_source()
            self.assertFalse(final.exists())
            self.assertEqual(list(final.parent.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS atomic installation promotion")
    def test_atomic_promotion_preserves_a_racing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / "source", root / "destination"
            source.mkdir()
            destination.mkdir()
            (source / "value").write_bytes(b"source")
            with self.assertRaises(OSError):
                setup.exclusive_rename(source, destination)
            self.assertTrue(destination.is_dir())
            self.assertEqual((source / "value").read_bytes(), b"source")

    def test_threading_symlink_is_preserved_without_reading_or_downloading(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "dll"
            original = Path(temporary) / "original"
            original.write_bytes(b"preserve")
            target.symlink_to(original)
            with patch.object(setup, "THREADING", target), \
                 patch.object(setup, "sha256", side_effect=AssertionError("Must reject link first")):
                with self.assertRaisesRegex(RuntimeError, "symbolic link"):
                    setup.acquire_threading()
            self.assertTrue(target.is_symlink())
            self.assertEqual(original.read_bytes(), b"preserve")

    def test_wrong_threading_file_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "dll"
            target.write_bytes(b"different")
            with patch.object(setup, "THREADING", target), \
                 patch.object(setup.subprocess, "run", side_effect=AssertionError("Unexpected network request")):
                with self.assertRaises(RuntimeError):
                    setup.acquire_threading()
            self.assertEqual(target.read_bytes(), b"different")

    def test_check_never_starts_helper_or_reads_keychain(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            game = root / "game"
            (game / "Installers").mkdir(parents=True)
            executable = bytearray(64)
            executable[:2] = b"MZ"
            struct.pack_into("<I", executable, 60, 64)
            (game / "Minecraft.Windows.exe").write_bytes(executable + b"PE\0\0\x64\x86")
            (game / "MicrosoftGame.Config").write_text(
                '<Game><Identity Version="1.0.0.0"/><StoreId>9NBLGGH2JHXJ</StoreId></Game>')
            (game / ".xodus-streaming.msixvc").write_bytes(b"metadata-fixture")
            (game / "Installers/GameInputRedist.msi").write_bytes(b"msi-fixture")
            helper, threading = root / "helper", root / "threading.dll"
            helper.write_bytes(b"helper-fixture")
            threading.write_bytes(b"dll-fixture")
            with patch.multiple(setup, HELPER=helper, THREADING=threading,
                                THREADING_SHA256=hashlib.sha256(b"dll-fixture").hexdigest()), \
                 patch.object(setup.subprocess, "run", side_effect=AssertionError("Unexpected process")), \
                 patch.object(setup.subprocess, "check_output", side_effect=AssertionError("Unexpected process")), \
                 redirect_stdout(io.StringIO()):
                self.assertEqual(setup.check(game), 0)


class InputRecoveryTests(unittest.TestCase):
    def prefix(self, root):
        prefix = root / "prefix"
        (prefix / "drive_c/windows/system32").mkdir(parents=True)
        (prefix / "system.reg").write_text("WINE REGISTRY Version 2\n")
        (prefix / "user.reg").write_text("WINE REGISTRY Version 2\n")
        return prefix

    def test_unknown_msi_fails_before_touching_prefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = self.prefix(root)
            msi = root / "unknown.msi"
            msi.write_bytes(b"unknown")
            with patch.object(gameinput, "require_idle", side_effect=AssertionError("Must reject MSI first")):
                with self.assertRaises(RuntimeError):
                    gameinput.install(prefix, msi, Path("/unused/wineserver"))
            self.assertFalse(gameinput.native_directory(prefix).exists())

    def test_busy_prefix_gets_no_files_or_registry(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = self.prefix(Path(temporary))
            with patch.object(gameinput, "payload", return_value={"fixture": b"payload"}), \
                 patch.object(gameinput, "require_idle", side_effect=RuntimeError("busy")):
                with self.assertRaises(RuntimeError):
                    gameinput.install(prefix, Path("/unused/msi"), Path("/unused/wineserver"))
            self.assertFalse(gameinput.native_directory(prefix).exists())
            self.assertFalse((prefix / ".standalone-gameinput.reg").exists())

    def test_external_symlink_cannot_pass_installed_file_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = self.prefix(root)
            directory = gameinput.native_directory(prefix)
            directory.parent.mkdir(parents=True)
            external = root / "external"
            external.mkdir()
            directory.symlink_to(external)
            self.assertFalse(any(gameinput.files_valid(prefix).values()))

    def test_registry_checks_follow_the_active_controlset(self):
        with tempfile.TemporaryDirectory() as temporary:
            prefix = self.prefix(Path(temporary))
            lines = ['WINE REGISTRY Version 2', '[System\\\\Select]', '"Current"=dword:00000002']
            for section, entries in gameinput.REGISTRY.items():
                section = section.replace("CurrentControlSet", "ControlSet002")
                lines.append("[" + section.replace("\\", "\\\\") + "]")
                for key, value in entries.items():
                    encoded = "dword:%08x" % value if isinstance(value, int) else '"' + value.replace("\\", "\\\\") + '"'
                    if key == "ImagePath":
                        encoded = "str(2):" + encoded
                    lines.append('"' + key + '"=' + encoded)
            (prefix / "system.reg").write_text("\n".join(lines))
            self.assertTrue(all(gameinput.registry_valid(prefix).values()))
            (prefix / "system.reg").write_text("\n".join(lines).replace('"Start"=dword:00000003', '"Start"=dword:00000004'))
            self.assertFalse(gameinput.registry_valid(prefix)[gameinput.SERVICE])


if __name__ == "__main__":
    unittest.main()
