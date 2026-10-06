#!/usr/bin/env python3
"""Build, stage, or restore local graphics optimizations for pinned DXMT."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'build/dxmt-shared-buffers'
PATCH = ROOT / 'patches/standalone-dxmt-shared-buffers.patch'
PATCHES = [PATCH]
STATUS_NAME = 'dxmt-shared-buffers.json'
BACKUP_NAME = 'dxmt-shared-backups'
MODIFICATION_NAME = 'shared_buffers'
COMMIT = '589adb780354b461645b29999cefaf533594ee99'
ARCHIVE_SHA = '8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d'
SHADER_SHA = '875e4990dcd818c6f4b5dfb697823afd0d2b851601f0b1e89ec0e5dd54bbf195'

def configure_profile(args):
    global OUT, PATCH, PATCHES, STATUS_NAME, BACKUP_NAME, MODIFICATION_NAME
    OUT = ROOT/'build/dxmt-shared-buffers'
    PATCH = ROOT/'patches/standalone-dxmt-shared-buffers.patch'
    PATCHES = [PATCH]
    STATUS_NAME = 'dxmt-shared-buffers.json'
    BACKUP_NAME = 'dxmt-shared-backups'
    MODIFICATION_NAME = 'shared_buffers'
    if args.packed_constants or args.reuse_input_layout:
        OUT = ROOT/'build/dxmt-packed-constants'
        PATCH = ROOT/'patches/standalone-dxmt-packed-constants.patch'
        PATCHES.append(PATCH)
        STATUS_NAME = 'dxmt-packed-constants.json'
        BACKUP_NAME = 'dxmt-packed-backups'
        MODIFICATION_NAME = 'packed_constants'
    if args.reuse_input_layout:
        OUT = ROOT/'build/dxmt-input-layout-reuse'
        PATCH = ROOT/'patches/standalone-dxmt-input-layout-reuse.patch'
        PATCHES.append(PATCH)
        STATUS_NAME = 'dxmt-input-layout-reuse.json'
        BACKUP_NAME = 'dxmt-input-layout-backups'
        MODIFICATION_NAME = 'input_layout_reuse'

def sha(data): return hashlib.sha256(data).hexdigest()
def run(*args, **kwargs): return subprocess.run(list(map(str,args)), check=True, **kwargs)
def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.'+path.name, dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.chmod(name,0o644); os.replace(name,path)
    finally:
        if os.path.exists(name): os.unlink(name)

def build(args):
    base=ROOT/'sources/dxmt'; source=OUT/'source'; output=OUT/'build'
    revision=subprocess.check_output(['git','-C',str(base),'rev-parse','HEAD'],text=True).strip()
    if revision != COMMIT: raise SystemExit('Unexpected DXMT source revision')
    if not source.exists():
        run('git','-C',base,'diff','--exit-code','HEAD')
        OUT.mkdir(parents=True,exist_ok=True)
        run('/bin/cp','-cR',base,source)
    run('git','-C',source,'submodule','update','--init','--recursive')
    for patch in PATCHES:
        applied=subprocess.run(['git','-C',str(source),'apply','--reverse','--check',str(patch)],capture_output=True)
        if applied.returncode: run('git','-C',source,'apply',patch)
    for relative,old in [('src/airconv/meson.build',"  subdir('darwin')"),('src/winemetal/meson.build',"  subdir('unix')")]:
        p=source/relative; p.write_text(p.read_text().replace(old,'# Reuse the pinned native bridge.'))
    archive=(ROOT/'downloads/dxmt-v0.80-builtin.tar.gz')
    if sha(archive.read_bytes()) != ARCHIVE_SHA: raise SystemExit('DXMT archive checksum mismatch')
    with tarfile.open(archive) as tar: original=tar.extractfile('v0.80/x86_64-windows/d3d11.dll').read()
    offset=original.find(b'MTLB\x01\x80'); length=struct.unpack_from('<Q',original,offset+16)[0]
    shader=original[offset:offset+length]
    if sha(shader) != SHADER_SHA: raise SystemExit('Embedded Metal library checksum mismatch')
    write(OUT/'dxmt_command.metallib',shader)
    run('xxd','-n','dxmt_command','-i',OUT/'dxmt_command.metallib',source/'src/dxmt/dxmt_command.h')
    p=source/'src/dxmt/meson.build';t=p.read_text()
    if 'dxmt_shaders_ir =' in t:
        t=t[:t.index('dxmt_shaders_ir =')]+"dxmt_shaders_header = files('dxmt_command.h')\n\n"+t[t.index('dxmt_lib ='):];p.write_text(t)
    env=dict(os.environ,LC_ALL='C',PATH=str(args.toolchain/'bin')+':'+str(args.python/'bin')+':'+os.environ['PATH'])
    meson=args.python/'bin/meson'
    if not (output/'build.ninja').exists():
        run(meson,'setup',output,source,'--cross-file',source/'build-win64.txt','--buildtype','release','-Dwine_install_path='+str(ROOT/'runtime/standalone/wine'),env=env)
    run(meson,'compile','-C',output,'-j',args.jobs,env=env)
    dll=(output/'src/d3d11/d3d11.dll').read_bytes()
    if b'Wine builtin DLL' not in dll[:128]: raise SystemExit('Missing Wine builtin marker')
    write(OUT/'d3d11.dll',dll)
    manifest={'source_commit':COMMIT,'patch_sha256':sha(PATCH.read_bytes()),'patches_sha256':{p.name:sha(p.read_bytes()) for p in PATCHES},'dll_sha256':sha(dll),'upstream_dll_sha256':sha(original),'metal_library_sha256':SHADER_SHA,'toolchain':str(args.toolchain),'validation':'Build only; GPU correctness and gameplay tests are separate.'}
    write(OUT/'manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    print('Built:',OUT/'d3d11.dll')

def stage(args, restore=False):
    wine=args.wine.resolve(); dxmt=args.dxmt.resolve()
    targets=[wine/'lib/wine/x86_64-windows/d3d11.dll',dxmt/'x86_64-windows/d3d11.dll']
    status=wine/STATUS_NAME
    mapped=subprocess.run(['/usr/sbin/lsof','-Fpn','--',*map(str,targets)],text=True,capture_output=True)
    if mapped.returncode not in (0,1) or mapped.stderr.strip() or any(x.startswith('p') for x in mapped.stdout.splitlines()): raise SystemExit('Close the target runtime before changing graphics DLLs')
    if restore:
        record=json.loads(status.read_text());backup=wine/record['backup'];data=backup.read_bytes()
        if sha(data)!=record['previous_sha256']: raise SystemExit('Backup checksum mismatch')
        if any(sha(t.read_bytes()) not in (record['dll_sha256'],record['previous_sha256']) for t in targets):
            raise SystemExit('Graphics DLL changed since staging; refusing to overwrite it')
        if 'manifest_backup' in record:
            previous_manifest=(wine/record['manifest_backup']).read_bytes()
            if sha(previous_manifest)!=record['manifest_backup_sha256']: raise SystemExit('Manifest backup checksum mismatch')
    else:
        manifest=json.loads((OUT/'manifest.json').read_text()); data=(OUT/'d3d11.dll').read_bytes()
        built_patches=manifest.get('patches_sha256',{PATCH.name:manifest['patch_sha256']})
        if sha(data)!=manifest['dll_sha256'] or built_patches!={p.name:sha(p.read_bytes()) for p in PATCHES}:
            raise SystemExit('Built artifact verification failed')
        previous=targets[0].read_bytes()
        if previous!=targets[1].read_bytes(): raise SystemExit('Target graphics copies disagree')
        if previous==data: print('Already staged');return
        if status.exists(): raise SystemExit('Restore the previously staged build of this profile first')
        backup=wine/BACKUP_NAME/('d3d11.dll.'+sha(previous))
        write(backup,previous)
        record=dict(manifest,previous_sha256=sha(previous),backup=str(backup.relative_to(wine)))
        previous_manifest=(dxmt/'manifest.json').read_bytes()
        manifest_backup=wine/BACKUP_NAME/('manifest.'+sha(previous_manifest)+'.json')
        write(manifest_backup,previous_manifest)
        record.update(manifest_backup=str(manifest_backup.relative_to(wine)),manifest_backup_sha256=sha(previous_manifest))
        # Record rollback information before replacing either copy.
        write(status,(json.dumps(record,indent=2)+'\n').encode())
    for target in targets: write(target,data)
    if any(sha(t.read_bytes())!=sha(data) for t in targets): raise SystemExit('Staged checksum verification failed')
    if restore:
        if 'manifest_backup' in record: write(dxmt/'manifest.json',previous_manifest)
        status.unlink()
    else:
        metadata=json.loads(previous_manifest)
        metadata['files']['x86_64-windows/d3d11.dll']=sha(data)
        metadata.setdefault('runtime_overlay',{})['x86_64-windows/d3d11.dll']={'sha256':sha(data)}
        metadata.setdefault('local_modifications',{})[MODIFICATION_NAME]=record
        write(dxmt/'manifest.json',(json.dumps(metadata,indent=2)+'\n').encode())
    print(('Restored' if restore else 'Staged')+' both graphics DLL copies; saves and settings unchanged.')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('build');p.add_argument('--toolchain',type=Path,default=ROOT/'build/performance/llvm-mingw-20251216-ucrt-macos-universal');p.add_argument('--python',type=Path,default=ROOT/'build/performance/python');p.add_argument('--jobs',type=int,default=6);p.add_argument('--packed-constants',action='store_true');p.add_argument('--reuse-input-layout',action='store_true',help='Include shared and packed buffers plus redundant input-layout reuse')
    for cmd in ('stage','restore'):
        p=sub.add_parser(cmd);p.add_argument('--wine',type=Path,default=ROOT/'runtime/standalone/wine');p.add_argument('--dxmt',type=Path,default=ROOT/'runtime/standalone/dxmt');p.add_argument('--packed-constants',action='store_true');p.add_argument('--reuse-input-layout',action='store_true',help='Select the separate input-layout reuse profile')
    args=parser.parse_args()
    configure_profile(args)
    if args.command=='build': build(args)
    else: stage(args,args.command=='restore')
