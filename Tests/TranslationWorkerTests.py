#!/usr/bin/env python3
"""Structural protection tests; does not import/download inference dependencies."""
import importlib.util
import pathlib
import os
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / "Resources/Translation/translate_worker.py"
spec = importlib.util.spec_from_file_location("worker", path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class ProtectedTextTests(unittest.TestCase):
    def protected(self, text, source="en"):
        parts, protected = worker.segments(text, source)
        return [value for enabled, value in parts if not enabled] + list(protected.values())

    def test_code_fences_and_open_fences(self):
        code = '```rust\nfn main() { println!("你好"); }\n```\n'
        self.assertEqual("".join(self.protected(code, "zh")), code)
        opened = "~~~python\nprint('hello')\n"
        self.assertEqual("".join(self.protected(opened)), opened)

    def test_inline_paths_identifiers_and_urls(self):
        text = "Check `cargo build` in src/main.rs and /tmp/demo.json using getStatus or user_id; visit https://example.test/docs."
        protected = "".join(self.protected(text))
        for literal in ["`cargo build`", "src/main.rs", "/tmp/demo.json", "getStatus", "user_id", "https://example.test/docs."]:
            self.assertIn(literal, protected)

    def test_chinese_translation_retains_existing_english(self):
        self.assertEqual("".join(self.protected("Rust code", "zh")), "Rust code")
        self.assertTrue(any(enabled for enabled, _ in worker.segments("检查这个项目", "zh")[0]))

    def test_indentation_and_markdown_structure(self):
        code = "    let value = 'do not translate';\n"
        self.assertEqual("".join(self.protected(code)), code)
        parts, protected = worker.segments("# Overview\n\n- Check the file.\n", "en")
        self.assertEqual("".join(value for _, value in parts), "# Overview\n\n- Check the file.\n")
        self.assertIn((False, "# "), parts)
        self.assertIn((False, "- "), parts)

    def test_long_clauses_are_bounded_without_dropping_content(self):
        value = "示" * 1300
        parts, protected = worker.segments(value, "zh")
        self.assertTrue(all(len(part) <= 500 for enabled, part in parts if enabled))
        self.assertEqual("".join(part for _, part in parts).replace(" ", ""), value)

    def test_context_is_kept_around_protected_literals(self):
        text = "请检查 `src/main.rs` 的错误，运行 `cargo test`，不要改动配置文件。"
        parts, protected = worker.segments(text, "zh")
        clauses = [part for enabled, part in parts if enabled]
        self.assertEqual(len(clauses), 1)
        self.assertIn("的错误，运行", clauses[0])
        self.assertEqual(worker.restore("".join(part for _, part in parts), protected), text)

    def test_placeholder_damage_is_rejected(self):
        with self.assertRaises(ValueError):
            worker.restore("Run CCAM0 twice CCAM0", {"CCAM0": "`cargo test`"})
        with self.assertRaises(ValueError):
            worker.restore("Run CAM0", {"CCAM0": "`cargo test`"})
        self.assertEqual(worker.restore("CCAM1 CCAM10", {"CCAM1": "one", "CCAM10": "ten"}), "one ten")

    def test_existing_marker_like_text_does_not_collide(self):
        source = "CCAM0 检查 `src/main.rs`。"
        parts, protected = worker.segments(source, "zh")
        self.assertNotIn("CCAM0", protected)
        self.assertEqual(worker.restore("".join(part for _, part in parts), protected), source)

    def test_uppercase_numeric_identifiers_are_protected(self):
        source = "Compare CCAM0 and ZXQ1 without changing `user_id`."
        parts, protected = worker.segments(source, "en")
        for literal in ["CCAM0", "ZXQ1", "`user_id`"]:
            self.assertIn(literal, protected.values())
        self.assertEqual(worker.restore("".join(part for _, part in parts), protected), source)

    def test_table_delimiters_and_code_only_cells_are_not_translated(self):
        source = "| File | Status |\n| :--- | ---: |\n| `a|b` | Ready |\n"
        parts, protected = worker.segments(source, "en")
        translated = [value.strip() for enabled, value in parts if enabled]
        self.assertEqual(translated, ["File", "Status", "Ready"])
        self.assertEqual(worker.restore("".join(part for _, part in parts), protected), source)


@unittest.skipUnless(os.environ.get("CCAM_TRANSLATION_TEST_HOME"), "set CCAM_TRANSLATION_TEST_HOME to run local model checks")
class LocalModelQualityTests(unittest.TestCase):
    def translate(self, text, source, target):
        return worker.translate(text, source, target, pathlib.Path(os.environ["CCAM_TRANSLATION_TEST_HOME"]))

    def test_chinese_code_instruction_keeps_sentence_context(self):
        text = "请检查 `src/main.rs` 的错误，运行 `cargo test`，不要改动配置文件。"
        result = self.translate(text, "zh", "en")
        for literal in ["`src/main.rs`", "`cargo test`"]:
            self.assertEqual(result.count(literal), 1)
        self.assertIn("error", result.lower())
        self.assertIn("run", result.lower())
        self.assertNotIn("Other Organiser", result)
        self.assertFalse(worker.HAN.search(result))

    def test_english_explanation_preserves_code_and_translates_prose(self):
        text = "Check the errors in `src/main.rs`, run `cargo test`, and do not change configuration files.\n\n```rust\nfn main() { println!(\"hello\"); }\n```\n"
        result = self.translate(text, "en", "zh")
        self.assertIn("检查", result)
        for literal in ["`src/main.rs`", "`cargo test`", '```rust\nfn main() { println!("hello"); }\n```\n']:
            self.assertEqual(result.count(literal), 1)
        self.assertNotIn("Check the errors", result)

    def test_paths_urls_and_identifiers_survive_both_directions(self):
        for text, source, target in [
            ("读取 /tmp/demo.json 并检查 getStatus，参考 https://example.test/docs。", "zh", "en"),
            ("Read /tmp/demo.json and inspect getStatus. See https://example.test/docs.", "en", "zh"),
        ]:
            result = self.translate(text, source, target)
            for literal in ["/tmp/demo.json", "getStatus", "https://example.test/docs"]:
                self.assertEqual(result.count(literal), 1)


if __name__ == "__main__":
    unittest.main()
