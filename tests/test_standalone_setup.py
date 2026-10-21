"""Offline setup/restart failure checks. Never read Keychain or run a game."""
import hashlib
import importlib.util
import io
import json
import os
import shutil
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

    def test_native_build_paths_reject_unsupported_names_and_resolved_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("has space", "has'quote", "has$dollar", "has;command", "has&operator",
                         "has:colon", "has,comma", "hasαunicode", "has\nnewline"):
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "Unsupported"):
                    native_dependencies.require_build_path(root / name, "fixture")
            outside = root / "unsupported target"
            outside.mkdir()
            alias = root / "safe-alias"
            alias.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "resolved targets"):
                native_dependencies.require_build_path(alias / "new-build", "fixture")
            self.assertEqual(native_dependencies.require_build_path(root / "valid-name_1.0+build", "fixture"),
                             root / "valid-name_1.0+build")
            self.assertFalse((outside / "new-build").exists())

    def test_build_environment_rejects_each_bad_tool_path_before_creating_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for invalid in ("prefix", "sdk", "clang", "pkg_config"):
                values = dict(prefix=root / "prefix", sdk="/sdk", clang="/clang", pkg_config="/pkg-config")
                values[invalid] = root / "unsupported path"
                with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "Unsupported"):
                    native_dependencies.build_environment(root, **values)
                self.assertEqual(set(root.iterdir()), set())

    def test_dependency_build_rejects_tool_paths_before_download_or_output_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for sdk, clang, pkg_config in (("/unsupported sdk", "/clang", "/pkg-config"),
                                            ("/sdk", "/unsupported compiler", "/pkg-config"),
                                            ("/sdk", "/clang", "/unsupported pkg-config")):
                destination = root / "new-build"
                with self.subTest(sdk=sdk, clang=clang, pkg_config=pkg_config), \
                        patch.object(native_dependencies.tarfile, "data_filter", object(), create=True), \
                        patch.object(native_dependencies.shutil, "which", return_value=pkg_config), \
                        patch.object(native_dependencies.subprocess, "check_output", side_effect=[sdk, clang]), \
                        patch.object(native_dependencies.subprocess, "run") as execute:
                    with self.assertRaisesRegex(ValueError, "Unsupported"):
                        native_dependencies.build(destination, 1)
                    execute.assert_not_called()
                self.assertFalse(destination.exists())

    def test_dependency_entrypoint_rejects_bad_destination_before_fetch_only_creates_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "unsupported destination"
            result = subprocess.run([sys.executable, "-B", str(ROOT / "tools/build-native-dependencies.py"),
                                     "--destination", str(destination), "--fetch-only"],
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unsupported dependency destination path", result.stderr)
            self.assertFalse(destination.exists())
            self.assertEqual(set(Path(temporary).iterdir()), set())

    def test_wine_entrypoint_rejects_bad_root_prefix_and_alias_without_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            unsupported_target = base / "unsupported target"
            unsupported_target.mkdir()
            alias = base / "dependency-alias"
            alias.symlink_to(unsupported_target, target_is_directory=True)
            for checkout_name, dependency in (("unsupported checkout", base / "safe-prefix"),
                                               ("safe-checkout-1", base / "unsupported prefix"),
                                               ("safe-checkout-2", alias)):
                checkout = base / checkout_name
                tools = checkout / "tools"
                tools.mkdir(parents=True)
                for name in ("build-standalone-wine.sh", "build-native-dependencies.py"):
                    shutil.copyfile(ROOT / "tools" / name, tools / name)
                before = {str(path.relative_to(checkout)) for path in checkout.rglob("*")}
                with self.subTest(checkout=checkout_name, dependency=dependency):
                    result = subprocess.run(["/bin/sh", str(tools / "build-standalone-wine.sh")],
                                            cwd=base, capture_output=True, text=True, timeout=10,
                                            env=dict(os.environ, STANDALONE_DEPENDENCY_PREFIX=str(dependency)))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Unsupported", result.stderr)
                    self.assertEqual(before, {str(path.relative_to(checkout)) for path in checkout.rglob("*")})
                    self.assertFalse((checkout / "build").exists())
                    self.assertFalse((checkout / "runtime").exists())
            self.assertEqual(set(unsupported_target.iterdir()), set())

    def test_supported_environment_passes_intact_arguments_to_compiler_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            compiler = root / "compiler-fixture"
            compiler.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            compiler.chmod(0o755)
            sdk, prefix = root / "sdk", root / "prefix"
            env = native_dependencies.build_environment(root, prefix, str(sdk), str(compiler), "/usr/bin/true")
            arguments = subprocess.check_output(["/bin/sh", "-c", "$CC $CPPFLAGS $LDFLAGS $ZLIB_CFLAGS -c fixture.c"],
                                                env=env, text=True).splitlines()
            for expected in (str(sdk), "-I" + str(prefix / "include"), "-L" + str(prefix / "lib"),
                             "-Wl,-rpath," + str(prefix / "lib"), "-I" + str(sdk / "usr/include"), "fixture.c"):
                self.assertIn(expected, arguments)

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
