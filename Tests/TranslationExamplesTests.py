#!/usr/bin/env python3
"""Optional real-model regression corpus. No model download or network use.

CCAM_TRANSLATION_TEST_HOME=/path/to/runtime /path/to/runtime/venv/bin/python3 \
  -I -B Tests/TranslationExamplesTests.py --report docs/TRANSLATION_EXAMPLES.md

Without CCAM_TRANSLATION_TEST_HOME all real-model tests are skipped, for CI.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "Resources/Translation/translate_worker.py"
FIXTURES = json.loads((Path(__file__).with_name("TranslationExamples.json")).read_text(encoding="utf-8"))
HOME = os.environ.get("CCAM_TRANSLATION_TEST_HOME")
RESULTS = {}


@unittest.skipUnless(HOME, "set CCAM_TRANSLATION_TEST_HOME to use existing local models")
class TranslationExamplesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("translation_example_worker", WORKER)
        cls.worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.worker)
        cls.home = Path(HOME)
        for direction in ("zh_en", "en_zh"):
            if not (cls.home / "models" / direction / "model/model.bin").is_file():
                raise RuntimeError("Local models are missing; tests never download them")


def example_test(case):
    def run(self):
        output = self.worker.translate(case["input"], case["source"], case["target"], self.home)
        self.assertIsInstance(output, str)
        self.assertTrue(output.strip())
        for literal in case["literals"]:
            self.assertEqual(output.count(literal), case["input"].count(literal),
                             "Protected literal changed, disappeared or duplicated: " + literal)
        if case.get("unchanged"):
            self.assertEqual(output, case["input"])
        else:
            self.assertNotEqual(output, case["input"])
            if case["target"] == "zh":
                self.assertRegex(output, r"[\u3400-\u9fff]")
            else:
                self.assertRegex(output, r"[A-Za-z]")
        if case.get("negation_regex"):
            # A structural regression guard, NOT a semantic equivalence proof.
            self.assertRegex(output, case["negation_regex"])
        if case.get("markdown_prefixes"):
            prefix = r"(?m)^(?:#{1,6} |[-*+] |\d+[.)] )"
            self.assertEqual(re.findall(prefix, output), re.findall(prefix, case["input"]))
            self.assertEqual(output.count("\n"), case["input"].count("\n"))
        if case.get("table"):
            self.assertEqual([line.count("|") for line in output.splitlines()],
                             [line.count("|") for line in case["input"].splitlines()])
            self.assertIn("| --- | --- |\n", output)
        RESULTS[case["id"]] = output
    return run


for fixture in FIXTURES:
    setattr(TranslationExamplesTests, "test_" + fixture["id"], example_test(fixture))


def write_report(path):
    from importlib.metadata import version
    if len(RESULTS) != len(FIXTURES):
        raise RuntimeError("Report requires every actual-model example to pass")
    parts = [
        "# 本地翻译真实样例验收\n",
        "这份记录由现有本地模型实际执行生成；未调用 Claude、公共翻译接口，也未下载任何内容。",
        f"\n共 {len(FIXTURES)} 个样例通过自动检查。引擎为 CTranslate2 {version('ctranslate2')} / "
        f"SentencePiece {version('sentencepiece')}，使用 Argos Translate 1.9 中英双向模型，CPU int8、beam 4。",
        "\n自动检查覆盖：非空输出、目标语言字符、代码/命令/标识符/路径/URL 的精确保留与出现次数、"
        "Markdown 标题列表及表格结构、纯代码和纯标点不变，以及选定句子的否定词保留。"
        "这些检查不等于语义完全准确；下方保留每一次真实输出，未人工润色。",
        "\n## 已知语义限制\n",
        "- 小模型可能误译短词：本次 `Notes` 译为 `页:1`，URL 示例中的 `steps` 译为 `台阶`。",
        "- 中文“项目/文件”在一例译为 `item/documents`，英文 `Do not commit changes` 译为“不执行更改”，Git 提交的精确含义丢失。",
        "- 本组禁止修改示例没有出现“允许修改”的直接反转，但仅检测否定词无法证明任意复杂否定都正确。",
        "- 代码内容完整保留，包括代码块中的中文字符串；翻译只作用于说明文字。",
        "- 翻译是阅读与输入辅助，不保证语义无损。聊天保留原文和实际发送的英文，方便对照；需要保持精确措辞时可关闭输入翻译。",
        "\n## 复现方式\n",
        "设置 `CCAM_TRANSLATION_TEST_HOME` 为已安装的本地模型目录，使用该目录的 Python 执行：",
        "\n```sh\n\"$CCAM_TRANSLATION_TEST_HOME/venv/bin/python3\" -I -B Tests/TranslationExamplesTests.py --report docs/TRANSLATION_EXAMPLES.md\n```\n",
        "未设置环境变量时，CI 会跳过真实模型测试；测试不会自动联网安装模型。",
        f"\nWorker SHA-256：`{hashlib.sha256(WORKER.read_bytes()).hexdigest()}`\n",
    ]
    for index, case in enumerate(FIXTURES, 1):
        direction = "中文 → 英文" if case["source"] == "zh" else "英文 → 中文"
        parts.extend([
            f"\n## {index}. {case['title']}（{direction}）\n",
            "原文：\n\n````text\n" + case["input"].rstrip("\n") + "\n````\n",
            "真实输出：\n\n````text\n" + RESULTS[case["id"]].rstrip("\n") + "\n````\n",
        ])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(parts), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="Write exact actual-model results after all examples pass")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(TranslationExamplesTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.report:
        if not HOME:
            parser.error("--report requires CCAM_TRANSLATION_TEST_HOME; no models are downloaded")
        write_report(args.report)
        print("Wrote actual-model report:", args.report)
