#!/usr/bin/env python3
"""Opt-in local Hy-MT2 regression; never downloads or requests Claude.
Run with --data-root /Volumes/Mac/CCAM-Translation [--cpu-only] [--report path].
CPU-only is a test override for sandboxes without Metal access.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value
worker = module('native_example_worker', ROOT / 'Resources/Translation/translate_worker.py')
native = module('native_example_engine', ROOT / 'Resources/Translation/native_translation.py')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-root', required=True, type=Path)
    parser.add_argument('--cpu-only', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    fixtures = json.loads((Path(__file__).with_name('TranslationExamples.json')).read_text())
    fixtures += [
        {'id':'technical_context','title':'Git 术语与条件','source':'en','target':'zh',
         'input':'The repository contains three commits on the feature branch. Resolve the merge conflict before deployment. Do not deploy until all tests pass.',
         'literals':[], 'required':['仓库','提交','分支','合并冲突','部署'], 'negation_regex':'不|勿|禁止'},
        {'id':'concurrency','title':'并发术语','source':'en','target':'zh',
         'input':'The callback may cause a race condition. Use idempotency to prevent duplicate refunds. A database migration must not introduce a deadlock.',
         'literals':[], 'required':['回调','竞态条件','幂等性','退款','数据库迁移','死锁'], 'negation_regex':'不|勿'},
        {'id':'technical_zh','title':'中文技术任务','source':'zh','target':'en',
         'input':'请检查 ～parrot-ai-server-rust～ 仓库的提交与分支，不要执行部署。先解决合并冲突，再运行 `cargo test`。',
         'literals':['parrot-ai-server-rust','`cargo test`'], 'remove_wrappers':True, 'negation_regex':'(?i)not|without'},
        {'id':'business_context','title':'业务与代码混合','source':'en','target':'zh',
         'input':'At checkout, validate the stock before creating a refund. Keep `order_id` unchanged and do not log the access token.',
         'literals':['`order_id`'], 'required':['结账','库存','退款','令牌'], 'negation_regex':'不|勿'},
        {'id':'engineering_ambiguity','title':'软件维护多义词','source':'en','target':'zh',
         'input':'Start on the housekeeping by reconciling the app branch. The remote commit `abc1234` changes the 3D viewer. Verify stock holds during acceptance before rollout.',
         'literals':['`abc1234`'], 'required':['清理维护','远程提交','查看器','库存预留','验收']},
    ]
    original_popen = subprocess.Popen
    def launch(command, **kwargs):
        command = command[:]
        if args.cpu_only:
            command[command.index('-ngl') + 1] = '0'; command += ['--device', 'none']
        return original_popen(command, **kwargs)
    results, failures = [], []
    with patch.object(native.subprocess, 'Popen', side_effect=launch):
        with native.NativeSession(args.data_root) as session:
            for case in fixtures:
                started = time.monotonic()
                parts, protected = native.translation_parts(case['input'], case['source'], worker)
                model_input = ' '.join(value for enabled, value in parts if enabled)
                for literal in case.get('excluded_from_model', []): assert literal not in model_input
                if any(enabled for enabled, value in parts):
                    output = worker.checked_segments(parts, protected, case['source'], lambda values: session.infer(values, case['source'], case['target']))
                else:
                    output = worker.strip_no_translate_delimiters(case['input'])
                errors = []
                if not output.strip(): errors.append('empty')
                for literal in case.get('literals', []):
                    if output.count(literal) != case['input'].count(literal): errors.append('literal: ' + repr(literal))
                if 'expected_output' in case and output != case['expected_output']: errors.append('exact output')
                if case.get('unchanged') and output != case['input']: errors.append('unchanged')
                if case.get('remove_wrappers') and '～' in output: errors.append('wrappers')
                if case.get('negation_regex') and not re.search(case['negation_regex'], output): errors.append('negation')
                for word in case.get('required', []):
                    if word not in output: errors.append('term: ' + word)
                if case.get('markdown_prefixes'):
                    prefix = r'(?m)^(?:#{1,6} |[-*+] |\d+[.)] )'
                    if re.findall(prefix, output) != re.findall(prefix, case['input']): errors.append('markdown prefix')
                    if output.count('\n') != case['input'].count('\n'): errors.append('markdown lines')
                if case.get('table'):
                    if [s.count('|') for s in output.splitlines()] != [s.count('|') for s in case['input'].splitlines()]: errors.append('table structure')
                    if '| --- | --- |\n' not in output: errors.append('table divider')
                seconds = round(time.monotonic() - started, 2)
                results.append({'case':case, 'output':output, 'seconds':seconds, 'errors':errors})
                print(('FAIL' if errors else 'PASS'), case['id'], seconds, errors, flush=True)
                if errors: failures.append(case['id'])
    if args.report:
        lines = ['# Hy-MT2 原生翻译实测', '',
                 '模型：Tencent Hy-MT2-1.8B Q8_0；运行时：llama.cpp b11871。模型与运行时均已校验官方 SHA-256。',
                 '测试设备：Apple M4 / 32 GB；本次设备后端：' + ('CPU（测试沙盒无法访问 Metal）' if args.cpu_only else '原生默认 Metal') + '。',
                 '只请求本机回环地址，无 Claude 或公共翻译 API 请求。复用一个本机模型进程逐条翻译；时间不包含模型首次加载，不能视作聊天端到端延迟。',
                 f'{len(results)-len(failures)}/{len(results)} 个样例通过结构、免译内容、指定术语及否定词检查。自动检查不证明任意文本语义完全准确；以下为未经润色的真实输出。',
                 '', '代码与免译内容在模型输入前隔离，输出后校验恢复。保护失败时保留原文并允许重试。', '']
        for result in results:
            case = result['case']
            lines += ['## ' + case['id'] + ' · ' + case['title'], '',
                      '耗时：' + str(result['seconds']) + ' 秒；检查：' + (', '.join(result['errors']) or '通过'), '',
                      '原文：', '````text', case['input'], '````', '输出：', '````text', result['output'], '````', '']
        args.report.write_text('\n'.join(lines), encoding='utf-8')
    if failures: raise SystemExit('Failed: ' + ', '.join(failures))

if __name__ == '__main__': main()
