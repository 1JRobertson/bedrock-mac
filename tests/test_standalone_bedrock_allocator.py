"""Build-input isolation and portable contract tests; never launch Wine or a game."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('exact_builder', ROOT / 'experiments/standalone-bedrock-allocator.py')
exact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exact)
run_spec = importlib.util.spec_from_file_location('exact_differential', ROOT / 'tests/run-bedrock-exact-differential.py')
differential = importlib.util.module_from_spec(run_spec)
run_spec.loader.exec_module(differential)


def added_files():
    """Read new-file hunks, whose exact bytes are pinned by the builder."""
    files = {}
    for chunk in exact.PATCH.read_text().split('--- /dev/null\n')[1:]:
        lines = chunk.splitlines(keepends=True)
        name = lines[0].removeprefix('+++ b/').strip()
        files[name] = ''.join(line[1:] for line in lines[2:] if line.startswith('+')).encode()
    return files


class ExactBuildTests(unittest.TestCase):
    def test_pinned_patch_and_headers(self):
        exact.check_patch()
        files = added_files()
        self.assertEqual(set(files), exact.EXTRA_HEADERS)
        for name, expected in exact.HEADERS.items():
            self.assertEqual(exact.sha(files['dlls/ntdll/' + name]), expected)

    def test_rejects_changed_patch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'changed.patch'
            path.write_bytes(exact.PATCH.read_bytes() + b'\n')
            with patch.object(exact, 'PATCH', path), self.assertRaisesRegex(RuntimeError, 'checksum'):
                exact.check_patch()

    def test_provenance_cannot_claim_stageable_or_tested(self):
        result = exact.manifest({'source_inputs_sha256': 'fixture'})
        self.assertFalse(result['default_enabled'])
        self.assertFalse(result['stageable'])
        self.assertNotIn('dll_sha256', result)
        self.assertEqual(result['prototype_dll_sha256'], exact.PROTOTYPE_DLL_SHA)

    def test_loader_normalization_rejects_partial_or_duplicate_hook(self):
        base = b'base loader\n'
        hook = (b'#include "bedrock_exact_support.h"\n#include "exact_adapter.h"\n'
                b'        bad_exact_pre_entry( wm->ldr.DllBase, wm->ldr.SizeOfImage );\n')
        self.assertEqual(exact.without_exact_hook(base + hook), base)
        for bad in (base, base + hook + hook, (base + hook).replace(b'bad_exact_pre_entry', b'wrong')):
            with self.assertRaisesRegex(RuntimeError, 'integration'):
                exact.without_exact_hook(bad)

    def test_prepare_rejects_input_overlap_before_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory).resolve() / 'source'
            source.mkdir()
            with patch.object(exact.heap, 'run') as run:
                for out in (source, source / 'build', source.parent):
                    with self.assertRaisesRegex(RuntimeError, 'overlap'):
                        exact.prepare(argparse.Namespace(source=source, output=out))
                run.assert_not_called()

    def test_build_uses_verified_dependency_headers_and_refuses_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); runtime = root / 'runtime'; runtime.mkdir()
            out = root / 'out'; source = root / 'source'; source.mkdir()
            args = argparse.Namespace(wine=runtime, output=out, jobs=1)
            flags = {'GNUTLS_CFLAGS': '-Iverified-gnutls', 'FREETYPE_CFLAGS': '-Iverified-freetype'}
            with patch.object(exact.ref, 'check_runtime'), \
                 patch.object(exact.heap, 'dependency_header_flags', return_value=flags) as headers, \
                 patch.object(exact, 'prepare', return_value=(source, out, {})), \
                 patch.object(exact.heap, 'output', return_value=b'/fixture-toolchain'), \
                 patch.object(exact.heap, 'run', side_effect=RuntimeError('stop before configure')) as run:
                with self.assertRaisesRegex(RuntimeError, 'stop before configure'):
                    exact.build(args)
                headers.assert_called_once_with(runtime)
                self.assertEqual({key: run.call_args.kwargs['env'][key] for key in flags}, flags)
            with patch.object(exact.ref, 'check_runtime'), \
                 patch.object(exact.heap, 'dependency_header_flags', side_effect=RuntimeError('tampered dependency')), \
                 patch.object(exact, 'prepare') as prepare:
                with self.assertRaisesRegex(RuntimeError, 'tampered dependency'):
                    exact.build(args)
                prepare.assert_not_called()

    def test_cli_has_no_stage_or_launch_command(self):
        result = subprocess.run(['python3', str(ROOT / 'experiments/standalone-bedrock-allocator.py'), '--help'],
                                capture_output=True, text=True, check=True)
        self.assertIn('{prepare,build}', result.stdout)
        result = subprocess.run(['python3', str(ROOT / 'experiments/standalone-bedrock-allocator.py'), 'stage'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)

    def test_differential_refuses_unknown_game_and_changed_instructions(self):
        with self.assertRaisesRegex(RuntimeError, 'executable SHA256'):
            differential.extract(b'unsupported executable')
        with self.assertRaisesRegex(RuntimeError, 'instruction guard'):
            differential.with_refmove(bytearray(8192))

    def test_contract_and_concurrent_reservations(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('C compiler unavailable; run on a development machine')
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            (out / 'current_reserve.h').write_bytes(added_files()['dlls/ntdll/current_reserve.h'])
            subprocess.run([compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pthread',
                            '-I', str(out), str(ROOT / 'tests/bedrock-exact-current.c'), '-o', str(out / 'contract')],
                           capture_output=True, text=True, check=True)
            result = subprocess.run([str(out / 'contract')], capture_output=True, text=True, check=True, timeout=30)
            self.assertIn('14000 concurrent reservations passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
