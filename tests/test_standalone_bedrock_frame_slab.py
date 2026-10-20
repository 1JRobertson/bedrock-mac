"""Frozen slab inputs, shared control ABI, and portable ownership regressions."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('frame_builder', ROOT / 'standalone-bedrock-frame-slab.py')
frame = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frame)
spec = importlib.util.spec_from_file_location('frame_control', ROOT / 'standalone-bedrock-frame-control.py')
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)


def added_files():
    files = {}
    for chunk in frame.PATCH.read_text().split('--- /dev/null\n')[1:]:
        lines = chunk.splitlines(keepends=True)
        name = lines[0].removeprefix('+++ b/').strip()
        files[name] = ''.join(line[1:] for line in lines[2:] if line.startswith('+')).encode()
    return files


class FrameSlabTests(unittest.TestCase):
    def test_pinned_layered_patch_and_headers(self):
        frame.check_patch()
        files = added_files()
        self.assertEqual(set(files), frame.EXTRA_HEADERS)
        for name, expected in frame.HEADERS.items():
            self.assertEqual(frame.sha(files['dlls/ntdll/' + name]), expected)

    def test_refuses_changed_layer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'changed.patch'; path.write_bytes(frame.PATCH.read_bytes() + b'\n')
            with patch.object(frame, 'PATCH', path), self.assertRaisesRegex(RuntimeError, 'checksum'):
                frame.check_patch()

    def test_loader_normalization_requires_all_three_integrations_once(self):
        base = b'exact-current base\n'
        hook = (b'#include "frame_adapter.h"\n'
                b'        bfr_pre_entry( wm->ldr.DllBase, wm->ldr.SizeOfImage );\n'
                b'    bfr_register_thread();\n')
        self.assertEqual(frame.without_frame_hook(base + hook), base)
        for data in (base, base + hook + hook, (base + hook).replace(b'bfr_register_thread', b'unknown')):
            with self.assertRaisesRegex(RuntimeError, 'integration'):
                frame.without_frame_hook(data)

    def test_profile_remains_build_only(self):
        record = frame.manifest({})
        self.assertFalse(record['default_enabled'])
        self.assertFalse(record['stageable'])
        self.assertNotIn('dll_sha256', record)
        self.assertEqual(record['maximum_reserved_bytes'], control.MAX_RESERVED)
        self.assertEqual(record['control_format']['size'], control.SIZE)
        self.assertEqual(record['control_format']['thread_stride'], control.ROW_STRIDE)
        self.assertEqual(record['prototype_dll_sha256'], frame.PROTOTYPE_DLL_SHA)

    def test_prepare_rejects_overlapping_input_and_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory).resolve() / 'source'; source.mkdir()
            with patch.object(frame.exact, 'prepare') as prepare:
                with self.assertRaisesRegex(RuntimeError, 'overlap'):
                    frame.prepare(argparse.Namespace(source=source, output=source / 'build'))
                prepare.assert_not_called()

    def test_build_uses_verified_dependency_headers_and_refuses_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); runtime = root / 'runtime'; runtime.mkdir()
            out = root / 'out'; source = root / 'source'; source.mkdir()
            args = argparse.Namespace(wine=runtime, output=out, jobs=1)
            flags = {'GNUTLS_CFLAGS': '-Iverified-gnutls', 'FREETYPE_CFLAGS': '-Iverified-freetype'}
            with patch.object(frame.ref, 'check_runtime'), \
                 patch.object(frame.heap, 'dependency_header_flags', return_value=flags) as headers, \
                 patch.object(frame, 'prepare', return_value=(source, out, {})), \
                 patch.object(frame.heap, 'output', return_value=b'/fixture-toolchain'), \
                 patch.object(frame.heap, 'run', side_effect=RuntimeError('stop before configure')) as run:
                with self.assertRaisesRegex(RuntimeError, 'stop before configure'):
                    frame.build(args)
                headers.assert_called_once_with(runtime)
                self.assertEqual({key: run.call_args.kwargs['env'][key] for key in flags}, flags)
            with patch.object(frame.ref, 'check_runtime'), \
                 patch.object(frame.heap, 'dependency_header_flags', side_effect=RuntimeError('tampered dependency')), \
                 patch.object(frame, 'prepare') as prepare:
                with self.assertRaisesRegex(RuntimeError, 'tampered dependency'):
                    frame.build(args)
                prepare.assert_not_called()

    def test_native_control_abi_matches_actual_adapter_declarations(self):
        cc = shutil.which('cc')
        if not cc:
            self.skipTest('Native C compiler unavailable')
        adapter = added_files()['dlls/ntdll/frame_adapter.h'].decode()
        declarations = '#define BFR_THREADS' + adapter.split('#define BFR_THREADS', 1)[1].split('struct bfr_saved_key', 1)[0]
        source = '#include <stdint.h>\n#include <stddef.h>\n#include <stdio.h>\n' + declarations
        source += 'int main(void) { printf("%zu %zu %zu %zu\\n", sizeof(struct bfr_control), sizeof(struct bfr_thread_counts), offsetof(struct bfr_control, requested_chunk), offsetof(struct bfr_control, threads)); }\n'
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory); (out / 'abi.c').write_text(source)
            subprocess.run([cc, '-std=c11', str(out / 'abi.c'), '-o', str(out / 'abi')], capture_output=True, check=True)
            result = subprocess.check_output([str(out / 'abi')], text=True).strip()
        self.assertEqual(result, f'{control.SIZE} {control.ROW_STRIDE} 24 128')

    def test_delayed_consumers_cache_reuse_and_allocation_failure(self):
        compiler = shutil.which('c++')
        if not compiler:
            self.skipTest('C++ compiler unavailable')
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            (out / 'frame_slab_core.h').write_bytes(added_files()['dlls/ntdll/frame_slab_core.h'])
            subprocess.run([compiler, '-std=c++17', '-O2', '-pthread', '-I', str(out),
                            str(ROOT / 'tests/bedrock-frame-slab.cpp'), '-o', str(out / 'contract')],
                           capture_output=True, text=True, check=True)
            result = subprocess.run([str(out / 'contract')], capture_output=True, text=True, check=True, timeout=30)
            self.assertIn('42000 delayed-reader allocations, 1000 cache/pool reuses', result.stdout)


if __name__ == '__main__':
    unittest.main()
