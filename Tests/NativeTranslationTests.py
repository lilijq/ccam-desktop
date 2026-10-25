import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
worker = module('protected_worker', ROOT / 'Resources/Translation/translate_worker.py')
native = module('native_worker', ROOT / 'Resources/Translation/native_translation.py')

class NativeProtectionTests(unittest.TestCase):
    def test_code_and_no_translate_islands_never_enter_model(self):
        source = '# Review\n\nRead `main.rs` and ～parrot-ai-server-rust～ before deployment.\n\n```rust\nfn main() { println!("～hello～"); }\n```\n'
        parts, protected = native.translation_parts(source, 'en', worker)
        model_input = '\n'.join(v for enabled, v in parts if enabled)
        for value in ['main.rs', 'parrot-ai-server-rust', 'fn main', 'hello']: self.assertNotIn(value, model_input)
        self.assertEqual(worker.checked_segments(parts, protected, 'en', lambda values: values), source.replace('～parrot-ai-server-rust～', 'parrot-ai-server-rust'))

    def test_paragraph_retains_context(self):
        text = 'The branch has diverged. The local repository has two commits. Do not deploy.'
        parts, protected = native.translation_parts(text, 'en', worker)
        self.assertEqual([s for enabled, s in parts if enabled], [text])
        self.assertIn('commits → 提交', native.prompt(text, 'en', 'zh'))
        self.assertIn('branch → 分支', native.prompt(text, 'en', 'zh'))

    def test_long_paragraph_preserves_all_content(self):
        source = 'Read `src/main.rs`. ' * 400
        parts, protected = native.translation_parts(source, 'en', worker)
        self.assertTrue(all(len(v) <= 2400 for enabled, v in parts if enabled))
        self.assertEqual(worker.checked_segments(parts, protected, 'en', lambda values: values), source)

    def test_missing_disk_is_explicit_no_legacy_fallback(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / 'native.json').write_text(json.dumps({'engine': native.ENGINE, 'dataRoot': '/not-mounted/test-model'}))
            with self.assertRaises(worker.TranslationFailure) as found:
                worker.translate('The commit is ready.', 'en', 'zh', home)
            self.assertEqual(found.exception.code, 'native_unavailable')

    def test_protected_only_text_never_starts_inference(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp); (home / 'native.json').write_text('{}')
            self.assertEqual(worker.translate('～～parrot-ai-server-rust～～', 'zh', 'en', home), 'parrot-ai-server-rust')

    def test_loopback_request_rejects_redirects(self):
        with self.assertRaises(ValueError): native.NoRedirect().redirect_request(None, None, 302, 'redirect', {}, 'https://example.test')

    def test_glossary_avoids_forcing_business_checkout_on_git(self):
        self.assertNotIn('checkout → 结账', native.prompt('Use git checkout to change branch.', 'en', 'zh'))

    def test_worker_accepts_existing_private_process_group(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'native.json').write_text('{}')
            result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'Resources/Translation/translate_worker.py'), '--home', temp],
                input=json.dumps({'text':'～keep_this～', 'source':'zh', 'target':'en'}), text=True,
                capture_output=True, start_new_session=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['translation'], 'keep_this')

if __name__ == '__main__': unittest.main()
