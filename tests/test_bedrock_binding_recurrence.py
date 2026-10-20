"""Run the observer's content, collision, history and budget contract."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def added_headers():
    files = {}
    patch = ROOT / 'patches/experimental-bedrock-binding-recurrence.patch'
    for chunk in patch.read_text().split('--- /dev/null\n')[1:]:
        lines = chunk.splitlines(keepends=True)
        name = lines[0].removeprefix('+++ b/dlls/ntdll/').strip()
        files[name] = ''.join(line[1:] for line in lines[2:] if line.startswith('+'))
    return files


class BindingRecurrenceTests(unittest.TestCase):
    def test_full_content_collision_and_bounded_history(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('Native C compiler unavailable')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            for name, content in added_headers().items():
                (output / name).write_text(content)
            subprocess.run([compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I', str(output), str(ROOT / 'tests/bedrock-binding-recurrence.c'),
                            '-o', str(output / 'contract')],
                           capture_output=True, text=True, check=True)
            result = subprocess.run([str(output / 'contract')], capture_output=True,
                                    text=True, check=True, timeout=15)
            self.assertIn('1044single-byte mutations, forced collisions', result.stdout)
            self.assertIn('LRU, bounds and16384cap', result.stdout)


if __name__ == '__main__':
    unittest.main()
