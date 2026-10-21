#!/usr/bin/env python3
"""Build the presentation-feedback candidate; never install implicitly."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/dxmt-frame-pacing'
BASE = ROOT / 'build/dxmt-input-layout-reuse'
BUILD = BASE / 'build'
PERF = ROOT / 'build/performance'
WINE = ROOT / 'runtime/standalone/wine'
env = dict(os.environ, PATH=str(PERF/'llvm-mingw-20251216-ucrt-macos-universal/bin') + ':' + os.environ['PATH'])
OUT.mkdir(exist_ok=True)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def run(command, cwd=OUT):
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)

baseline = json.loads((BASE/'manifest.json').read_text())
assert digest(BUILD/'src/d3d11/d3d11.dll') == baseline['dll_sha256']
original = (BASE/'source/src/d3d11/d3d11_swapchain.cpp').read_text()
source = original.replace('  uint32_t frame_latency;',
    '  const uint32_t preferred_max_frame_latency = Config::getInstance().getOption<int>("d3d11.maxFrameLatency", 0);\n  uint32_t frame_latency;')
source = source.replace('    cmd_queue.PresentBoundary();',
    '    if (preferred_max_frame_latency > 0 && preferred_max_frame_latency <= DXGI_MAX_SWAP_CHAIN_BUFFERS)\n'
    '      cmd_queue.SetMaxLatency(std::min(cmd_queue.GetMaxLatency(), preferred_max_frame_latency));\n'
    '    cmd_queue.PresentBoundary();')
assert source != original and source.count('preferred_max_frame_latency') == 4
(OUT/'d3d11_swapchain.cpp').write_text(source)
entry = next(r for r in json.loads((BUILD/'compile_commands.json').read_text()) if r['file'].endswith('d3d11_swapchain.cpp'))
command = shlex.split(entry['command']); obj = OUT/'d3d11_swapchain.cpp.obj'
for flag in ('-MQ', '-MF', '-o', '-c'):
    command[command.index(flag)+1] = str(OUT/'d3d11_swapchain.cpp' if flag == '-c' else Path(str(obj)+'.d') if flag == '-MF' else obj)
run(command, BUILD)
link = subprocess.check_output([str(PERF/'python/bin/ninja'), '-C', str(BUILD), '-t', 'commands', 'src/d3d11/d3d11.dll'], text=True).splitlines()[-1]
command = [str(obj) if a == entry['output'] else a for a in shlex.split(link)]
command[command.index('-o')+1] = str(OUT/'d3d11.dll')
command = ['-Wl,--out-implib='+str(OUT/'d3d11.dll.a') if a.startswith('-Wl,--out-implib=') else a for a in command]
run(command, BUILD)
run([WINE/'bin/winebuild', '--builtin', OUT/'d3d11.dll'])
assert b'Wine builtin DLL' in (OUT/'d3d11.dll').read_bytes()[:128]

# Start from the existing bridge with its validated ColorSync/autorelease fixes.
memory = ROOT/'build/dxmt-memory-unix'
metadata = json.loads((memory/'unix-bridge-manifest.json').read_text())
native_source = memory/'source/src/winemetal/unix/winemetal_unix.c'
assert digest(native_source) == metadata['patched_source_sha256']
source = native_source.read_text()
helper = '''
#include <stdlib.h>
#include <string.h>
#include "experiments/standalone-dxmt-present-trace.h"
static bool bedrock_present_pacing;
__attribute__((constructor)) static void bedrock_pacing_init(void) {
  const char *enabled = getenv("BEDROCK_DXMT_PRESENT_PACING");
  bedrock_present_pacing = enabled && !strcmp(enabled, "1");
}
'''
source = source.replace('static NTSTATUS\n_MTLCommandBuffer_presentDrawable',
    helper + (ROOT/'experiments/standalone-dxmt-present-pacer.m').read_text() + '\nstatic NTSTATUS\n_MTLCommandBuffer_presentDrawable', 1)
for field, duration in [('arg','0.0'), ('arg0','params->arg1')]:
    needle = '  [(id<MTLCommandBuffer>)params->handle presentDrawable:(id<MTLDrawable>)params->'+field
    source = source.replace(needle, '  bedrock_pace_present((id<MTLDrawable>)params->'+field+');\n'
        '  bedrock_trace_present((id<MTLDrawable>)params->'+field+', '+duration+');\n'+needle, 1)
source = source.replace('layer.displaySyncEnabled = props->display_sync_enabled;', 'layer.displaySyncEnabled = bedrock_present_pacing || props->display_sync_enabled;')
source = source.replace('params->ret = (obj_handle_t)[(CAMetalLayer *)params->handle nextDrawable];',
    'bedrock_wait_previous_present((CAMetalLayer *)params->handle);\n  params->ret = (obj_handle_t)[(CAMetalLayer *)params->handle nextDrawable];')
assert source.count('  bedrock_pace_present(') == 2 and source.count('  bedrock_trace_present(') == 2
(OUT/'winemetal_unix.c').write_text(source)
shutil.copy2(memory/'winemetal-upstream.so', OUT/'winemetal-upstream.so')
headers = ROOT/'sources/dxmt'
common = ['/usr/bin/clang','-arch','x86_64','-mmacosx-version-min=15.0','-O2']
includes = [headers/'include', headers/'src/winemetal/unix', headers/'src/winemetal', headers/'src/airconv', ROOT]
run(common+['-std=gnu2x','-fno-objc-arc','-ObjC']+['-I'+str(p) for p in includes]+['-c',OUT/'winemetal_unix.c','-o',OUT/'winemetal_unix.o'])
run(common+['-std=gnu2x','-fno-objc-arc','-Wall','-Wextra','-Werror','-c',ROOT/'experiments/standalone-dxmt-present-trace.m','-o',OUT/'present-trace.o'])
run(common+['-std=c11','-c',ROOT/'native/graphics/standalone-dxmt-display-trace.c','-o',OUT/'display-trace.o'])
run(common+['-dynamiclib',OUT/'winemetal_unix.o',OUT/'present-trace.o',OUT/'display-trace.o',OUT/'winemetal-upstream.so',WINE/'lib/wine/x86_64-unix/ntdll.so',WINE/'lib/wine/x86_64-unix/winemac.so',
    '-framework','Cocoa','-framework','Metal','-framework','MetalFX','-framework','ColorSync','-framework','QuartzCore','-Wl,-install_name,@rpath/winemetal-frame-pacing.so','-Wl,-rpath,@loader_path','-o',OUT/'winemetal.so'])
run(['/usr/bin/install_name_tool','-change','@rpath/winemetal.so','@loader_path/winemetal-upstream.so','-id','@rpath/winemetal.so',OUT/'winemetal.so'])
run(['/usr/bin/codesign','--force','--sign','-',OUT/'winemetal.so'])
metadata.update(status='Frame pacing candidate; validation required before staging.',
    files={name:digest(OUT/name) for name in ('winemetal.so','winemetal-upstream.so')},
    patched_source_sha256=digest(OUT/'winemetal_unix.c'),
    presentation_pacer_sha256=digest(ROOT/'experiments/standalone-dxmt-present-pacer.m'),
    presentation_trace_sha256=digest(ROOT/'experiments/standalone-dxmt-present-trace.m'))
(OUT/'unix-bridge-manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
(OUT/'manifest.json').write_text(json.dumps(dict(dll_sha256=digest(OUT/'d3d11.dll'), native_sha256=digest(OUT/'winemetal.so'), baseline=baseline, swapchain_source_sha256=digest(OUT/'d3d11_swapchain.cpp'), validation='pending'),indent=2)+'\n')
print('Built',OUT)
