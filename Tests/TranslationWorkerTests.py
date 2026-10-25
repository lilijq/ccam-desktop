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

    def assert_shielded(self, source, literals, language="zh", exact=True):
        for marker in ["CCAM", "ZXQ"]:
            parts, protected = worker.segments(source, language, marker)
            model_input = " ".join(value for enabled, value in parts if enabled)
            restored = worker.restore("".join(value for _, value in parts), protected)
            for literal in literals:
                body = worker.fullwidth_body(literal) if literal.startswith("～") else literal
                self.assertIn(body, protected.values())
                self.assertNotIn(body, model_input)
                self.assertEqual(restored.count(body), source.count(body))
            if exact:
                self.assertEqual(restored, worker.strip_no_translate_delimiters(source))
            return_values = (parts, protected, model_input, restored)
        return return_values

    def test_fullwidth_single_double_multiple_and_multiline(self):
        literals = ["～免译甲～", "～～保留乙\n以及第二行～～", "～保留丙～"]
        source = "请解释 " + "，并保留 ".join(literals) + "。"
        _, _, model_input, _ = self.assert_shielded(source, literals)
        for content in ["免译甲", "保留乙", "以及第二行", "保留丙"]:
            self.assertNotIn(content, model_input)
        self.assertIn("请解释", model_input)

    def test_unclosed_fullwidth_marker_keeps_everything_to_end(self):
        for delimiter in ["～", "～～"]:
            literal = delimiter + "不要翻译\n第二行 `src/main.rs`\n```rust\nfn main() {}\n```\n末尾"
            source = "请先解释。" + literal
            _, _, model_input, _ = self.assert_shielded(source, [literal])
            self.assertNotIn("不要翻译", model_input)
            self.assertNotIn("末尾", model_input)
            self.assertTrue(any(enabled for enabled, _ in worker.segments(source, "zh")[0]))

    def test_protected_only_clause_is_not_sent_to_model_after_sentence_split(self):
        source = "Explain the project. ～～Keep this exact English.\nNever translate this tail."
        parts, protected = worker.segments(source, "en")
        self.assertEqual([value for enabled, value in parts if enabled], ["Explain the project."])
        self.assertEqual(worker.restore("".join(value for _, value in parts), protected), source.replace("～～", "", 1))

    def test_fullwidth_marker_inside_code_does_not_capture_following_prose(self):
        for code in ['```rust\nlet label = "～孤立";\n```\n', '~~~python\nprint("～～孤立")\n~~~\n', '    print("～孤立")\n']:
            source = code + "后面的说明需要翻译。"
            parts, protected = worker.segments(source, "zh")
            self.assertIn("后面的说明需要翻译", " ".join(value for enabled, value in parts if enabled))
            self.assertEqual(worker.restore("".join(value for _, value in parts), protected), source)

    def test_fullwidth_marker_inside_inline_code_has_code_priority(self):
        source = "解释 `～孤立`，后面的说明需要翻译。"
        _, _, model_input, _ = self.assert_shielded(source, ["`～孤立`"])
        self.assertIn("后面的说明需要翻译", model_input)

    def test_fullwidth_literal_may_contain_code_urls_and_table_delimiters(self):
        literal = "～～保留 `user_id` 和 https://example.test/?a=1|b=2\n```json\n{\"x\":1}\n```～～"
        self.assert_shielded("说明 " + literal + "，不要更改。", [literal])
        source = "| 内容 | 状态 |\n| --- | --- |\n| ～甲|乙～ | 需要检查 |\n"
        parts, _, model_input, restored = self.assert_shielded(source, ["～甲|乙～"])
        self.assertNotIn("甲", model_input)
        self.assertIn((False, "|"), parts)
        self.assertEqual(source.count("|"), restored.count("|"))

    def test_fullwidth_original_markers_and_nested_literals_are_not_masked_twice(self):
        literal = "～CCAM0 ZXQ1 `getStatus` src/main.rs～"
        source = "保留 CCAM0、ZXQ1 和 " + literal + "，检查 `cargo test`。"
        for marker in ["CCAM", "ZXQ"]:
            parts, protected = worker.segments(source, "zh", marker)
            self.assertIn(literal[1:-1], protected.values())
            self.assertFalse(any(key in value for key in protected for value in protected.values()))
            self.assertEqual(worker.restore("".join(value for _, value in parts), protected), source.replace(literal, literal[1:-1]))

    def test_marker_names_inside_untranslated_fences_cannot_collide(self):
        source = '```rust\nlet label = "CCAM0 ZXQ0";\n```\n解释 ～保留中文～ 和 `main.rs`。'
        for marker in ["CCAM", "ZXQ"]:
            parts, protected = worker.segments(source, "zh", marker)
            self.assertNotIn(marker + "0", protected)
            self.assertEqual(worker.restore("".join(value for _, value in parts), protected), source.replace("～保留中文～", "保留中文"))

    def test_adjacent_islands_and_ascii_neighbors_have_separate_model_tokens(self):
        literals = ["～甲～", "～乙～", "～～丙～～"]
        source = "Keep～甲～～乙～and～～丙～～unchanged."
        _, _, model_input, restored = self.assert_shielded(source, literals, "en", exact=False)
        self.assertIn("Keep", model_input)
        self.assertIn("unchanged", model_input)
        for literal in literals:
            self.assertIn(worker.fullwidth_body(literal), restored)
        self.assertNotIn("～", restored)

    def test_no_inference_path_strips_wrappers_and_preserves_source_spacing(self):
        examples = [
            ("～parrot-ai-server-rust～", "parrot-ai-server-rust"),
            ("～～parrot-ai-server-rust～～", "parrot-ai-server-rust"),
            ("Keep～parrot-ai-server-rust～unchanged.", "Keepparrot-ai-server-rustunchanged."),
            ("  ～first-name～\t～～second_name～～\n", "  first-name\tsecond_name\n"),
            ("～～第一行\n第二行 English～～", "第一行\n第二行 English"),
            ("prefix ～Keep this\nexact tail.", "prefix Keep this\nexact tail."),
            ("prefix ～～Keep this\nexact tail.", "prefix Keep this\nexact tail."),
            ("～", ""), ("～～", ""), ("～～～～", ""),
        ]
        # No real runtime is required: these inputs must never load a model.
        for source, expected in examples:
            self.assertEqual(worker.translate(source, "zh", "en", pathlib.Path("/not-installed")), expected)

    def test_no_inference_code_and_unmarked_english_are_byte_identical(self):
        for source in [
            "  Keep user_id, getStatus and ~/src/main.rs unchanged.\n",
            "`～code～` and `～～more_code～～`", "~~~python\nprint('～code')\n~~~\n",
            '```rust\nlet name = "～～x～～";\n```\n', "    print('～code')\n",
            "~ and ~~strikethrough~~", "!?...\n",
        ]:
            self.assertEqual(worker.translate(source, "zh", "en", pathlib.Path("/not-installed")), source)

    def test_only_wrapped_content_is_unwrapped_in_both_directions(self):
        source = "～～保留第一行\nEnglish stays exact.～～"
        expected = "保留第一行\nEnglish stays exact."
        for language, target in [("zh", "en"), ("en", "zh")]:
            self.assertEqual(worker.translate(source, language, target, pathlib.Path("/not-installed")), expected)

    def test_ascii_tilde_strikethrough_and_fence_rules_are_unchanged(self):
        source = "说明 ~ 和 ~~删除线~~。\n~~~rust\nfn main() {}\n~~~\n后文需要翻译。"
        parts, protected = worker.segments(source, "zh")
        model_input = " ".join(value for enabled, value in parts if enabled)
        self.assertIn("~~删除线~~", model_input)
        self.assertIn("后文需要翻译", model_input)
        self.assertNotIn("fn main", model_input)
        self.assertEqual(worker.restore("".join(value for _, value in parts), protected), source)


class SegmentRecoveryTests(unittest.TestCase):
    def test_retry_only_damaged_segment(self):
        calls = []
        def infer(values):
            calls.append(values)
            return [v.replace("CCAM0", "BROKEN") if len(calls) == 1 else v for v in values]
        source = "Read `main.rs`. Check configuration."
        parts, protected = worker.segments(source, "en")
        self.assertEqual(worker.checked_segments(parts, protected, "en", infer), source)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(calls[1]), 1)
        self.assertNotIn("Check configuration", calls[1][0])

    def test_literal_islands_survive_both_damaged_marker_passes(self):
        calls = []
        def infer(values):
            calls.append(values)
            return [v.replace("CCAM0", "BROKEN").replace("ZXQ0", "BROKEN") for v in values]
        source = "Read `main.rs` carefully."
        parts, protected = worker.segments(source, "en")
        self.assertEqual(worker.checked_segments(parts, protected, "en", infer), source)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all("main.rs" not in v and "CCAM" not in v and "ZXQ" not in v for v in calls[2]))

    def test_empty_batch_and_invented_markers_are_rejected(self):
        for infer in [lambda values: [], lambda values: ["Invented CCAM999" for v in values]]:
            parts, protected = worker.segments("Check configuration.", "en")
            with self.assertRaises(worker.TranslationFailure):
                worker.checked_segments(parts, protected, "en", infer)

    def test_marker_spacing_is_reversible(self):
        source = "Read `main.rs` carefully."
        parts, protected = worker.segments(source, "en")
        self.assertEqual(worker.checked_segments(parts, protected, "en", lambda values: [v.replace("CCAM0", "ccam 0") for v in values]), source)


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
