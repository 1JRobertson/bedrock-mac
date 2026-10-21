#!/usr/bin/env python3
"""Collect exact frozen-worker notices from PyInstaller TOCs and verified sources.
Read-only for worker, build inputs, venv and Homebrew packages; no compilation or
execution of the worker. Python 3.11+ required. Original code: GPL-3.0.
"""
import argparse,ast,email,gzip,hashlib,io,json,re,struct,subprocess,tarfile,urllib.request
from pathlib import Path,PurePosixPath

NOTICE=re.compile(r'(?i)^(licenses?|licences?|copying|notices?|copyright)(?:$|[._-])')
COPYRIGHT=re.compile(r'(?i)(copyright|permission is hereby granted|redistribution and use|SPDX-License-Identifier)')


def sha(data):return hashlib.sha256(data).hexdigest()
class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        if not newurl.startswith('https://'):raise ValueError('Non-HTTPS redirect refused')
        return super().redirect_request(req,fp,code,msg,headers,newurl)
def fetch(url):
    if not url.startswith('https://'):raise ValueError('HTTPS source required')
    with urllib.request.build_opener(HTTPSOnly()).open(url,timeout=40) as response:return response.read()
def save(root,name,data):
    path=PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name:raise ValueError('Unsafe output path')
    dest=root/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
    return {'path':name,'sha256':sha(data),'bytes':len(data)}
def triples(value):
    if isinstance(value,(tuple,list)):
        if len(value)==3 and all(isinstance(x,str) for x in value):yield tuple(value)
        else:
            for part in value:yield from triples(part)
def read_toc(path):return list(triples(ast.literal_eval(path.read_text())))
def cellar_root(path):
    resolved=path.resolve();parts=resolved.parts
    if 'Cellar' not in parts:raise ValueError('Expected recorded Homebrew source: '+path.name)
    at=parts.index('Cellar');return Path(*parts[:at+3])
def text_section(path):
    """Hash __TEXT,__text without loading code; signatures/install names are separate."""
    data=path.read_bytes()
    if len(data)<32 or struct.unpack_from('<I',data)[0]!=0xfeedfacf:return None
    count=struct.unpack_from('<I',data,16)[0];offset=32
    for _ in range(count):
        cmd,size=struct.unpack_from('<II',data,offset)
        if size<8 or offset+size>len(data):raise ValueError('Malformed Mach-O load command')
        if cmd==0x19:
            sections=struct.unpack_from('<I',data,offset+64)[0]
            for number in range(sections):
                pos=offset+72+number*80
                if pos+80>offset+size:raise ValueError('Malformed Mach-O section')
                name,segment,_,length,start=struct.unpack_from('<16s16sQQI',data,pos)
                if name.rstrip(b'\0')==b'__text' and segment.rstrip(b'\0')==b'__TEXT':
                    if start+length>len(data):raise ValueError('Mach-O text outside file')
                    return sha(data[start:start+length])
        offset+=size
    return None

def source_archive(cache,spec):
    path=cache/spec['filename']
    data=path.read_bytes() if path.is_file() else fetch(spec['url'])
    if sha(data)!=spec['sha256']:raise ValueError('Source checksum mismatch: '+spec['component'])
    cache.mkdir(parents=True,exist_ok=True)
    if not path.exists():path.write_bytes(data)
    files={}
    with tarfile.open(fileobj=io.BytesIO(data),mode='r:*') as archive:
        for member in archive:
            if not member.isfile():continue
            parts=PurePosixPath(member.name).parts
            if member.name.startswith('/') or '..' in parts or '\\' in member.name:raise ValueError('Unsafe source path')
            name='/'.join(parts[1:])
            if name in files:raise ValueError('Duplicate source path')
            files[name]=archive.extractfile(member).read()
    return files

def comment_notices(name,data):
    try:text=data.decode('utf-8')
    except UnicodeDecodeError:return []
    if name.endswith(('.c','.h')):blocks=re.findall(r'/\*.*?\*/',text,re.S)
    elif name.endswith('.py'):
        blocks=[];current=[]
        for line in text.splitlines(keepends=True):
            if line.lstrip().startswith('#') or (current and not line.strip()):current.append(line)
            elif current:blocks.append(''.join(current));current=[]
        if current:blocks.append(''.join(current))
    else:return []
    return [block.encode() for block in blocks if COPYRIGHT.search(block)]

def collect(args):
    worker=args.worker.resolve();toc=args.toc_dir.resolve();venv=args.venv.resolve();out=args.output.absolute()
    if out.exists() or out.is_symlink():raise ValueError('Output must be a new directory')
    if not worker.is_dir() or not toc.is_dir() or not venv.is_dir():raise ValueError('Missing input directory')
    out.mkdir(parents=True);cache=args.source_cache.resolve() if args.source_cache else out/'source-archives'
    collect_rows=read_toc(toc/'COLLECT-00.toc')
    all_rows=[];toc_hashes={}
    for name in ('COLLECT-00.toc','Analysis-00.toc','PKG-00.toc','PYZ-00.toc'):
        data=(toc/name).read_bytes();toc_hashes[name]=sha(data);all_rows+=read_toc(toc/name)
        save(out,'internal/'+name,data)
    rows={};components={};binaries=[]
    for name,origin,kind in collect_rows:
        if kind not in ('BINARY','EXTENSION','EXECUTABLE'):continue
        path=worker/name if kind=='EXECUTABLE' else worker/'_internal'/name
        if path.is_symlink() or not path.is_file():raise ValueError('Missing regular worker binary: '+name)
        source=Path(origin)
        loads=subprocess.check_output(['otool','-L',str(path)],text=True).splitlines()[1:]
        before,after=text_section(source),text_section(path)
        if before is not None and after!=before:raise ValueError('Bundled code differs from TOC source: '+name)
        row={'path':str(path.relative_to(worker)),'type':kind,'sha256':sha(path.read_bytes()),'toc_source_sha256':sha(source.read_bytes()),'text_section_sha256':after,'source_text_section_matches':before is not None and before==after,'native_loads':[l.strip().split(' (')[0] for l in loads]}
        if kind=='EXECUTABLE':row['component']='PyInstaller bootloader + project worker'
        else:
            root=cellar_root(source);component=root.parent.name;row['component']=component;row['component_version']=root.name;row['source_relative_to_component']=str(source.resolve().relative_to(root));components[component]=root
        binaries.append(row)
    expected_binary_paths={x['path'] for x in binaries}
    for path in worker.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(worker):raise ValueError('Worker symlink escapes bundle')
            continue
        if not path.is_file():continue
        with path.open('rb') as stream:magic=stream.read(4)
        if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf') and str(path.relative_to(worker)) not in expected_binary_paths:
            raise ValueError('Worker contains native binary missing from TOC: '+str(path.relative_to(worker)))
    specs=[];license_records=[];files_by_component={};formula_records=[]
    for component,root in sorted(components.items()):
        formula_path=next((root/'.brew').glob('*.rb'));formula=formula_path.read_text()
        url=re.search(r'^  url "([^"]+)"',formula,re.M)[1];expected=re.search(r'^  sha256 "([0-9a-f]{64})"',formula,re.M)[1]
        spec={'component':component,'version':root.name,'url':url,'sha256':expected,'filename':component.replace('@','-')+'-'+root.name+'.tar.gz'}
        specs.append(spec);files=source_archive(cache,spec);files_by_component[component]=files
        record=save(out,'build-source-evidence/'+component.replace('@','-')+'-formula.rb',formula.encode());record.update(component=component,version=root.name);formula_records.append(record)
        receipt=json.loads((root/'INSTALL_RECEIPT.json').read_text())
        clean={k:receipt[k] for k in ('built_as_bottle','poured_from_bottle','compiler','runtime_dependencies') if k in receipt}
        clean['source']={k:v for k,v in receipt.get('source',{}).items() if k!='path'}
        save(out,'build-source-evidence/'+component.replace('@','-')+'-receipt.json',(json.dumps(clean,indent=2)+'\n').encode())
        # Native package root notices; do not label non-shipped utilities as components.
        for name,data in sorted(files.items()):
            if '/' not in name and NOTICE.match(name):
                record=save(out,'licenses/'+component.replace('@','-')+'/'+name,data);record.update(component=component,source_member=name,source_archive=spec)
                license_records.append(record)
    site=next((venv/'lib').glob('python*/site-packages'))
    dist=next(site.glob('pyinstaller-*.dist-info'))
    metadata=email.message_from_string((dist/'METADATA').read_text());version=metadata['Version']
    py_meta=json.loads(fetch(f'https://pypi.org/pypi/pyinstaller/{version}/json'))
    sdist=next(x for x in py_meta['urls'] if x['packagetype']=='sdist')
    pyi_spec={'component':'pyinstaller','version':version,'url':sdist['url'],'sha256':sdist['digests']['sha256'],'filename':sdist['filename']}
    specs.append(pyi_spec);pyi=source_archive(cache,pyi_spec)
    pyi_copying=(dist/'licenses/COPYING.txt').read_bytes()
    if pyi_copying!=pyi['COPYING.txt']:raise ValueError('Installed PyInstaller license differs from release source')
    record=save(out,'licenses/PyInstaller/COPYING.txt',pyi_copying);record.update(component='pyinstaller',source_member='COPYING.txt',source_archive=pyi_spec);license_records.append(record)
    pycomponent=next(x for x in components if x.startswith('python@'));pyfiles=files_by_component[pycomponent];pyspec=next(x for x in specs if x['component']==pycomponent)
    for name in ('Doc/license.rst','Doc/copyright.rst'):
        record=save(out,'licenses/CPython/'+name.replace('/','-')+'.txt',pyfiles[name]);record.update(component='CPython embedded/history',source_member=name,source_archive=pyspec);license_records.append(record)
    installed_license=(components[pycomponent]/'LICENSE').read_bytes()
    if installed_license!=pyfiles['LICENSE']:raise ValueError('Installed CPython root license differs from release source')
    # Map each included extension to its exact release source stanza.
    setup=pyfiles['Modules/Setup.stdlib.in'].decode().replace('\\\n',' ');module_sources={}
    for line in setup.splitlines():
        line=re.sub(r'@[^@]+@','',line).strip()
        if not line or line.startswith('#'):continue
        parts=line.split();module_sources[parts[0]]=['Modules/'+p for p in parts[1:] if p.endswith('.c')]
    source_paths=set();modules=[];unknown=[]
    pyroot=components[pycomponent]
    stdlib=next((pyroot/'Frameworks/Python.framework/Versions').glob('*/lib/python*'))
    original_stdlib={name:Path(origin) for name,origin,kind in all_rows if kind=='PYMODULE' and Path(origin).is_relative_to(stdlib)}
    for name,origin,kind in sorted(set(all_rows)):
        if kind not in ('PYMODULE','PYSOURCE','EXTENSION'):continue
        path=Path(origin);record={'module':name,'type':kind}
        if 'localpycs' in path.parts and kind=='PYMODULE':
            record['toc_representation']='PyInstaller-generated local pyc; source association by module name'
            if name in original_stdlib:path=original_stdlib[name]
            elif ('PyInstaller/loader/'+name+'.py') in pyi:path=site/'PyInstaller/loader'/(name+'.py')
            else:unknown.append(name);record['component']='unclassified compiled module';modules.append(record);continue
        if kind=='EXTENSION':
            module=Path(name).name.split('.cpython-')[0];source_names=module_sources.get(module,[])
            record.update(component='CPython',source_members=source_names)
            source_paths.update(source_names)
        elif path.is_relative_to(stdlib):
            relative='Lib/'+str(path.relative_to(stdlib));record.update(component='CPython',source_member=relative)
            if relative in pyfiles:
                source_paths.add(relative);record['source_matches_upstream']=path.read_bytes()==pyfiles[relative]
                if not record['source_matches_upstream']:record['installed_source']=save(out,'build-source-evidence/installed-python/'+relative,path.read_bytes())
            else:
                record['source_status']='generated or modified installer source; exact installed source retained'
                record['installed_source']=save(out,'build-source-evidence/installed-python/'+relative,path.read_bytes())
        elif path.is_relative_to(site/'PyInstaller'):
            relative=str(path.relative_to(site));relative=relative[:-1] if relative.endswith('.pyc') else relative
            record.update(component='PyInstaller',source_member=relative)
            if relative in pyi:
                for block in comment_notices(relative,pyi[relative]):
                    digest=sha(block);n=save(out,'licenses/PyInstaller/embedded-'+digest[:16]+'.txt',block);n.update(component='PyInstaller runtime',source_member=relative,source_archive=pyi_spec);license_records.append(n)
        elif 'site-packages' in path.parts:
            record['component']='unclassified third-party module';unknown.append(name)
        else:record['component']='project application code';record['license_scope']='project GPL license and source supplied separately'
        modules.append(record)
    # HACL headers contain licenses not present in Doc/license.rst. Include all
    # distinct source notice blocks for that exact bundled hash implementation.
    source_paths.update(n for n in pyfiles if n.startswith('Modules/_hacl/') and n.endswith(('.c','.h')))
    source_paths.update(n for n in pyfiles if n.startswith(('Objects/mimalloc/','Include/internal/mimalloc/')) and n.endswith(('.c','.h')))
    grouped={}
    for name in sorted(source_paths):
        if name not in pyfiles:continue
        for block in comment_notices(name,pyfiles[name]):
            grouped.setdefault(sha(block),{'data':block,'members':[]})['members'].append(name)
    for key,value in grouped.items():
        record=save(out,'licenses/CPython/embedded-'+key[:16]+'.txt',value['data']);record.update(component='CPython embedded code',source_members=value['members'],source_archive=pyspec);license_records.append(record)
    # Preserve zstd/xxHash's separate copyright header alongside selected BSD terms.
    zstd=files_by_component.get('zstd',{})
    if 'lib/common/xxhash.h' in zstd:
        block=re.search(rb'/\*.*?\*/',zstd['lib/common/xxhash.h'],re.S)[0]
        record=save(out,'licenses/zstd/xxhash-copyright.txt',block);record.update(component='zstd/xxHash',source_member='lib/common/xxhash.h',source_archive=next(x for x in specs if x['component']=='zstd'));license_records.append(record)
    unicode_version=re.search(rb'#define UNIDATA_VERSION "([^"]+)"',pyfiles['Modules/unicodedata_db.h'])[1].decode()
    for name,url in [('Unicode-database-ReadMe.txt',f'https://www.unicode.org/Public/{unicode_version}/ucd/ReadMe.txt'),('Unicode-LICENSE-V3.txt','https://www.unicode.org/license.txt')]:
        data=fetch(url);record=save(out,'licenses/Unicode/'+name,data);record.update(component='Unicode '+unicode_version,source_url=url,scope='Exact database-version notice plus current official Unicode License V3, copied unchanged; not a claim of archived historical license bytes');license_records.append(record)
    changes=(f'This distribution embeds a subset of Homebrew CPython {pyspec["version"]} and its standard library using PyInstaller {version}.\nNative load commands and code signatures are adjusted for app-bundle packaging; all inspected native code sections match their recorded input binaries.\nHomebrew modifies sysconfig and generates installation-specific _sysconfigdata. Exact installed versions and the Homebrew build formula are retained as source evidence.\nOriginal CPython license terms and embedded-code notices remain applicable.\n').encode()
    record=save(out,'licenses/CPython/MODIFICATIONS.txt',changes);record['component']='Distribution changes summary';license_records.append(record)
    # Byte-identical notice blocks can be referenced by more than one module.
    by_path={}
    for record in license_records:
        if record['path'] not in by_path:by_path[record['path']]=record
        elif 'source_member' in record:
            by_path[record['path']].setdefault('additional_source_members',[]).append(record['source_member'])
    license_records=list(by_path.values())
    index={'schema':1,'status':'notice-materials-ready-pending-packager-integration-and-review','target':'Frozen worker identified by file hashes, not directory name','worker_sha256':sha((worker/'BedrockWorker').read_bytes()),'python_version':pyspec['version'],'pyinstaller_version':version,'toc_sha256':toc_hashes,'binary_inventory':binaries,'module_inventory':modules,'source_archives':specs,'license_files':license_records,'build_formula_records':formula_records,'unclassified_python_modules':unknown,'source_scope':{'python':'Exact official release source plus recorded Homebrew formula, source checksum and installed receipt. Formula patch bytes/build environment not all reconstructed.','native':'Exact upstream sources/notices and Homebrew version/formula. This is not a from-source reproduction of Homebrew bottles.','pyinstaller':'Exact PyPI release sdist and installed notice match. Worker bootloader origin is TOC-based, not a reproducible bootloader build claim.'},'observations':{'extensions':sum(x['type']=='EXTENSION' for x in binaries),'bundled_native_files':len(binaries),'code_sections_matching_toc':sum(x['source_text_section_matches'] for x in binaries),'license_files':len(license_records)},'limits':['Only the worker was audited; Wine/DXMT/helper notices are separate.','CPython license documentation is itself described upstream as incomplete; per-file embedded notices collected conservatively.','System dylibs/frameworks are runtime dependencies, not copied into the worker.','Packaging/signing changes full binary bytes; matching text-section hashes support unchanged code, not a full reproducible-build claim.','No build, worker execution, credentials, saves or game inspection performed.','internal/ TOCs contain private build paths and must not be shipped.']}
    save(out,'index.json',(json.dumps(index,indent=2)+'\n').encode())
    report=REPORT.replace('Python 3.14.5 has 42 compiled extensions',f"Python {pyspec['version']} has {index['observations']['extensions']} compiled extensions")
    for component,label,old in [('openssl@3','OpenSSL','3.6.3'),('xz','XZ/liblzma','5.8.4'),('mpdecimal','mpdecimal','4.0.1')]:
        if component in components:report=report.replace(label+' '+old,label+' '+components[component].name)
    if 'zstd' in components:report=report.replace('zstd 1.5.7 (Homebrew revision 1)','zstd '+components['zstd'].name+' (Homebrew package version)')
    report=report.replace('Unicode 16.0.0','Unicode '+unicode_version)
    save(out,'PACKAGING.md',report.encode())
    print(json.dumps(index['observations']|{'python':pyspec['version'],'pyinstaller':version,'unclassified_python_modules':unknown},indent=2))

REPORT='''# Frozen Python worker license input

Copy only `licenses/` into the candidate's license resources, and retain `index.json`
as component/source evidence. Do not copy `internal/`, source archives, build receipts,
or build formula files into the app. Re-run against RC2's final worker and TOCs.

The collection includes CPython's PSF/history license, exact-version embedded-code
license documentation and source notice blocks (including HACL*), PyInstaller's full
GPL/bootloader exception/Apache terms, and the worker's actual bundled native-library
notices. HACL copyright naming Microsoft does not make this a proprietary Microsoft
payload; this is the unchanged MIT notice from CPython's open-source hash code.

For this inspected worker, Python 3.14.5 has 42 compiled extensions. OpenSSL 3.6.3,
XZ/liblzma 5.8.4, mpdecimal 4.0.1 and zstd 1.5.7 (Homebrew revision 1) are bundled.
The library component of XZ is 0BSD; other XZ utility licenses included by its source
package do not establish that those utilities were shipped. BSD terms are available
for zstd; its upstream GPL alternative is preserved without claiming GPL was chosen.
System zlib, libbz2, libffi and libexpat are not bundled copies.

PyInstaller bootloader/loader terms contain an embedding exception; runtime hooks
have Apache-2.0 terms. The exception does not remove Python/native dependency terms.
No unrelated venv package is labeled shipped merely because it was installed.

Source archives are checksum-verified against the exact installed Homebrew formula
or PyPI release metadata. Source URLs/digests and formula/receipt evidence are retained.
Homebrew patches and complete bottle build inputs are not fully reconstructed; do not
claim a from-source reproducible worker. The index maps each compiled extension to
its exact CPython release source and every binary to its recorded TOC input. It records
both complete-file hashes and code-section comparisons across packaging/signing.

Unicode 16.0.0 is identified from CPython's generated database. Its versioned database
notice and the current official Unicode License V3 are preserved unchanged; the latter
is explicitly not claimed to be an archived 2024 license file.

This is component evidence and packaging input, not blanket legal assurance or a
publication approval. Keep the project's GPL source/notice material alongside this
worker dependency collection.
'''

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--worker',required=True,type=Path);p.add_argument('--toc-dir',required=True,type=Path);p.add_argument('--venv',required=True,type=Path);p.add_argument('--output',required=True,type=Path);p.add_argument('--source-cache',type=Path)
    args=p.parse_args()
    try:collect(args)
    except (OSError,ValueError,KeyError,StopIteration,tarfile.TarError,subprocess.CalledProcessError) as e:p.exit(1,'Collection stopped: '+str(e)+'\nOutput is incomplete; retry with a new output directory.\n')
if __name__=='__main__':main()
