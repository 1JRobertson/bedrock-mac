import ast,importlib.util,io,struct,tarfile,tempfile,unittest
from pathlib import Path
script=Path(__file__).resolve().parents[1]/'tools/collect-python-notices.py'
spec=importlib.util.spec_from_file_location('collector',script);collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
class Tests(unittest.TestCase):
    def test_toc_is_literal_only(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'a.toc';p.write_text("__import__('os').getcwd()")
            with self.assertRaises(ValueError):collector.read_toc(p)
    def test_nested_toc_entries(self):
        self.assertEqual(list(collector.triples([False,[('a','b','BINARY')]])),[('a','b','BINARY')])
    def test_c_license_header_kept_complete(self):
        data=b'/* MIT License\nCopyright holder\nPermission is hereby granted.\nDisclaimer. */\nint x;'
        self.assertEqual(collector.comment_notices('a.c',data),[data.split(b'\nint x;')[0]])
    def test_macho_section_hash_and_malformed_bounds(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'binary'
            header=struct.pack('<8I',0xfeedfacf,0x100000c,0,6,1,152,0,0)
            segment=struct.pack('<II16sQQQQIIII',0x19,152,b'__TEXT',0,3,184,3,7,5,1,0)
            section=struct.pack('<16s16sQQIIIIIIII',b'__text',b'__TEXT',0,3,184,0,0,0,0,0,0,0)
            p.write_bytes(header+segment+section+b'abc')
            self.assertEqual(collector.text_section(p),collector.sha(b'abc'))
            p.write_bytes(header+segment+section)
            with self.assertRaises(ValueError):collector.text_section(p)
if __name__=='__main__':unittest.main()
