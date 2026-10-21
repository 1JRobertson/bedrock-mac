#!/usr/bin/env python3
"""Build the HUD on the validated pacing bridge without changing the live runtime."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/metrics-hud'
BASE=ROOT/'build/dxmt-frame-pacing'
WINE=ROOT/'runtime/standalone/wine'
OUT.mkdir(exist_ok=True)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def run(command): subprocess.run(list(map(str,command)),check=True)
metadata=json.loads((BASE/'unix-bridge-manifest.json').read_text())
assert digest(BASE/'winemetal_unix.c')==metadata['patched_source_sha256']
source=(BASE/'winemetal_unix.c').read_text()
source='#include "experiments/standalone-metrics-hud.h"\n'+source
source=source.replace('  bedrock_trace_present(', '  bedrock_hud_present((id<MTLDrawable>)params->arg);\n  bedrock_trace_present(',1)
needle='  bedrock_trace_present((id<MTLDrawable>)params->arg0,'
source=source.replace(needle,'  bedrock_hud_present((id<MTLDrawable>)params->arg0);\n'+needle,1)
needle='    layer.pixelFormat = to_metal_pixel_format(props->pixel_format);'
assert source.count(needle)==1
source=source.replace(needle,needle+'\n    bedrock_hud_attach(layer);')
assert source.count('  bedrock_hud_present(')==2
(OUT/'winemetal_unix.c').write_text(source)
headers=ROOT/'sources/dxmt'
common=['/usr/bin/clang','-arch','x86_64','-mmacosx-version-min=15.0','-O2']
includes=[headers/'include',headers/'src/winemetal/unix',headers/'src/winemetal',headers/'src/airconv',ROOT]
run(common+['-std=gnu2x','-fno-objc-arc','-ObjC']+['-I'+str(p) for p in includes]+['-c',OUT/'winemetal_unix.c','-o',OUT/'winemetal_unix.o'])
run(common+['-fobjc-arc','-Wall','-Wextra','-Werror','-c',ROOT/'experiments/standalone-metrics-hud.m','-o',OUT/'metrics-hud.o'])
run(common+['-std=gnu2x','-fno-objc-arc','-c',ROOT/'experiments/standalone-dxmt-present-trace.m','-o',OUT/'present-trace.o'])
run(common+['-std=c11','-c',ROOT/'native/graphics/standalone-dxmt-display-trace.c','-o',OUT/'display-trace.o'])
shutil.copy2(BASE/'winemetal-upstream.so',OUT/'winemetal-upstream.so')
run(common+['-dynamiclib',OUT/'winemetal_unix.o',OUT/'metrics-hud.o',OUT/'present-trace.o',OUT/'display-trace.o',OUT/'winemetal-upstream.so',WINE/'lib/wine/x86_64-unix/ntdll.so',WINE/'lib/wine/x86_64-unix/winemac.so',
 '-framework','Cocoa','-framework','Metal','-framework','MetalFX','-framework','ColorSync','-framework','QuartzCore','-framework','CoreText','-Wl,-install_name,@rpath/winemetal-metrics.so','-Wl,-rpath,@loader_path','-o',OUT/'winemetal.so'])
run(['/usr/bin/install_name_tool','-change','@rpath/winemetal.so','@loader_path/winemetal-upstream.so','-id','@rpath/winemetal.so',OUT/'winemetal.so'])
run(['/usr/bin/codesign','--force','--sign','-',OUT/'winemetal.so'])
metadata.update(status='HUD candidate; validation pending',files={name:digest(OUT/name) for name in ['winemetal.so','winemetal-upstream.so']},
 patched_source_sha256=digest(OUT/'winemetal_unix.c'),metrics_hud_sha256=digest(ROOT/'experiments/standalone-metrics-hud.m'))
(OUT/'unix-bridge-manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
print('Built HUD native bridge:',metadata['files']['winemetal.so'])
