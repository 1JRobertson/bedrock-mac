import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import sys

script=Path(__file__).with_name('collect-helper-licenses.py')
if not script.is_file():script=Path(__file__).resolve().parents[1]/'collect-helper-licenses.py'
collector = None
if sys.version_info >= (3, 11):
    spec = importlib.util.spec_from_file_location('collector', script)
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)

def archive(entries):
    buffer=io.BytesIO()
    with tarfile.open(fileobj=buffer,mode='w') as output:
        for name,kind in entries:
            info=tarfile.TarInfo(name)
            if kind=='link':info.type=tarfile.SYMTYPE;info.linkname='/etc/passwd';output.addfile(info)
            else:info.size=1;output.addfile(info,io.BytesIO(b'x'))
    return buffer.getvalue()

@unittest.skipUnless(collector is not None, "Source collector requires Python 3.11+")
class CollectorTests(unittest.TestCase):
    def test_rejects_parent_paths(self):
        with self.assertRaises(ValueError):collector.archive_files(archive([('../secret','file')]))
    def test_rejects_duplicate_paths(self):
        with self.assertRaises(ValueError):collector.archive_files(archive([('a','file'),('a','file')]))
    def test_source_links_rejected_notice_scan_never_follows_them(self):
        data=archive([('LICENSE','file'),('external','link')])
        with self.assertRaises(ValueError):collector.archive_files(data)
        self.assertEqual(set(collector.archive_files(data,skip_nonregular=True)),{'LICENSE'})
    def test_archives_deterministic(self):
        files={'a':(b'hello',0o644)}
        self.assertEqual(collector.tar_bytes(files,'source'),collector.tar_bytes(files,'source'))
    def test_source_verification_rejects_extra_changed_and_symlink_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);project=root/'project';source=root/'source'
            (project/'patches').mkdir(parents=True);source.mkdir()
            (project/'patches/Cargo.lock').write_text('lock')
            for source_name, destination in collector.HELPER_INPUTS.items():
                original = project/source_name
                original.parent.mkdir(parents=True, exist_ok=True)
                original.write_text(source_name)
                target = source/destination
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(source_name)
            (source/'Cargo.lock').write_text('lock')
            helper=source/'crates/xodus-cli/examples/standalone_helper.rs';helper.parent.mkdir(parents=True,exist_ok=True)
            upstream=collector.tar_bytes({'Cargo.lock':(b'old',0o644)},'upstream')
            config={'patches':[]}
            self.assertEqual(len(collector.validate_xodus(project,source,config,upstream)),4)
            for source_name, destination in collector.HELPER_INPUTS.items():
                target = source/destination
                target.write_text('tampered')
                with self.assertRaises(ValueError):collector.validate_xodus(project,source,config,upstream)
                target.write_text(source_name)
            (source/'unapproved.json').write_text('x')
            with self.assertRaises(ValueError):collector.validate_xodus(project,source,config,upstream)
            (source/'unapproved.json').unlink();helper.write_text('modified')
            with self.assertRaises(ValueError):collector.validate_xodus(project,source,config,upstream)
            helper.unlink();helper.symlink_to(project/'standalone-helper.rs')
            with self.assertRaises(ValueError):collector.validate_xodus(project,source,config,upstream)

if __name__=='__main__':unittest.main()
