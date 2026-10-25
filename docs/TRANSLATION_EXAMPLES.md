# 本地翻译真实样例验收

这份记录由现有本地模型实际执行生成；未调用 Claude、公共翻译接口，也未下载任何内容。

共 42 个样例通过自动检查。引擎为 CTranslate2 4.4.0 / SentencePiece 0.2.0，使用 Argos Translate 1.9 中英双向模型，CPU int8、beam 4。

自动检查覆盖：非空输出、目标语言字符、代码/命令/标识符/路径/URL 的精确保留与出现次数、Markdown 标题列表及表格结构、纯代码和纯标点不变，以及选定句子的否定词保留。这些检查不等于语义完全准确；下方保留每一次真实输出，未人工润色。

## 全角波浪号免译约定

`～内容～` 与 `～～内容～～` 都会保留内容、移除外层包裹符，支持多段、多行；例如 `～parrot-ai-server-rust～` 输出 `parrot-ai-server-rust`。未闭合时仅去掉开头标记，其后至文本末尾的内容保持原样。免译内容在分段阶段就被遮蔽，不会进入本地翻译模型输入；原占位符同名文字、代码、链接及表格可组合使用。

代码围栏、行内代码与缩进代码优先保留，其中孤立的 `～` 不会把后续说明吞入免译区域。代码中的全角波浪号不删除。ASCII `~`、`~~删除线~~`、`~~~` 围栏沿用原有规则。需要翻译正文时，免译区域外侧空格可能被整理；只有英文正文、纯免译或纯代码而无需翻译时，除显式包裹符外的字符及空白逐字保留。

## 已知语义限制

- 小模型可能误译短词：本次 `Notes` 译为 `页:1`，URL 示例中的 `steps` 译为 `台阶`。
- 中文“项目/文件”在一例译为 `item/documents`，英文 `Do not commit changes` 译为“不执行更改”，Git 提交的精确含义丢失。
- 本组禁止修改示例没有出现“允许修改”的直接反转，但仅检测否定词无法证明任意复杂否定都正确。
- 代码内容完整保留，包括代码块中的中文字符串；翻译只作用于说明文字。
- 翻译是阅读与输入辅助，不保证语义无损。聊天保留原文和实际发送的英文，方便对照；需要保持精确措辞时可关闭输入翻译。

## 复现方式

设置 `CCAM_TRANSLATION_TEST_HOME` 为已安装的本地模型目录，使用该目录的 Python 执行：

```sh
"$CCAM_TRANSLATION_TEST_HOME/venv/bin/python3" -I -B Tests/TranslationExamplesTests.py --report docs/TRANSLATION_EXAMPLES.md
```

未设置环境变量时，CI 会跳过真实模型测试；测试不会自动联网安装模型。

Worker SHA-256：`3eb4e99d67f7ac73fda1ba6e580fe4229a34b556853c028357225a0d5a5ffb40`


## 1. 中文禁止修改（中文 → 英文）

原文：

````text
请检查这个项目，不要修改任何文件。
````

真实输出：

````text
Please check this item and do not modify any documents.
````


## 2. 英文禁止修改（英文 → 中文）

原文：

````text
Inspect this project. Do not modify any files.
````

真实输出：

````text
请检查一下这个项目 不修改任何文件 。
````


## 3. Rust 代码块（中文 → 英文）

原文：

````text
请解释这段代码，不要修改它。
```rust
fn main() { println!("你好"); }
```
````

真实输出：

````text
Please explain the code and do not modify it.
```rust
fn main() { println!("你好"); }
```
````


## 4. Swift 代码块（英文 → 中文）

原文：

````text
This function returns a greeting.
```swift
func greet() -> String { "hello" }
```
````

真实输出：

````text
此函数返回问候 。
```swift
func greet() -> String { "hello" }
```
````


## 5. Python 代码块（中文 → 英文）

原文：

````text
解释下面的函数，并给出测试建议。
```python
def add(a, b):
    return a + b
```
````

真实输出：

````text
explains the functions below and gives the test recommendations.
```python
def add(a, b):
    return a + b
```
````


## 6. 中文多段行内代码（中文 → 英文）

原文：

````text
请检查 `src/main.rs` 的错误，运行 `cargo test`，不要改动配置文件。
````

真实输出：

````text
Check the `src/main.rs` error, run `cargo test`, without changing the configuration file.
````


## 7. 英文多个标识符（英文 → 中文）

原文：

````text
Call `getStatus()` with `user_id` and inspect `result.value`.
````

真实输出：

````text
与`user_id`呼叫`getStatus()`,并检查`result.value`.
````


## 8. 中文带查询参数 URL（中文 → 英文）

原文：

````text
请参考 https://example.test/docs?q=rust&lang=en#usage 并说明步骤。
````

真实输出：

````text
Please refer to https://example.test/docs?q=rust&lang=en#usage and indicate the steps.
````


## 9. 英文带查询参数 URL（英文 → 中文）

原文：

````text
See https://example.test/docs?q=rust&lang=en#usage for the steps.
````

真实输出：

````text
台阶见https://example.test/docs?q=rust&lang=en#usage.
````


## 10. Windows 路径（中文 → 英文）

原文：

````text
读取 C:\work\app\main.rs 并说明错误。
````

真实输出：

````text
Read C:\work\app\main.rs and explain the error.
````


## 11. Unix 与用户目录路径（英文 → 中文）

原文：

````text
Read /tmp/demo.json and ~/app/src/main.rs without changing either file.
````

真实输出：

````text
读取 /tmp/demo.json 和 ~/app/src/main.rs 不更改文件 。
````


## 12. Git 命令与参数（中文 → 英文）

原文：

````text
运行 `git diff --stat -- src/main.rs`，只查看变化。
````

真实输出：

````text
Run `git diff --stat -- src/main.rs`, see only changes.
````


## 13. 未加反引号的命令（英文 → 中文）

原文：

````text
Run git status --short before making changes.
````

真实输出：

````text
在更改前运行 git status --short 。
````


## 14. 中文标题与列表（中文 → 英文）

原文：

````text
# 检查步骤

- 读取文件。
- 运行测试。

## 注意事项
不要提交改动。
````

真实输出：

````text
# Check steps

- Reads the file.
- Run tests.

## Attention
Do not submit changes.
````


## 15. 英文标题与编号列表（英文 → 中文）

原文：

````text
# Review steps

1. Read the files.
2. Run the tests.

## Notes
Do not commit changes.
````

真实输出：

````text
# 审查步骤

1. 阅读文件。
2. 运行测试。

## 页:1
不执行更改。
````


## 16. Markdown 表格（英文 → 中文）

原文：

````text
| File | Status |
| --- | --- |
| `src/main.rs` | Ready for review |
````

真实输出：

````text
| 文件 | 状态 |
| --- | --- |
| `src/main.rs` | 准备接受审查 |
````


## 17. JSON 配置代码块（中文 → 英文）

原文：

````text
说明这个配置。
```json
{"name":"demo","enabled":true}
```
````

真实输出：

````text
Description of this configuration.
```json
{"name":"demo","enabled":true}
```
````


## 18. YAML 配置代码块（英文 → 中文）

原文：

````text
Keep this configuration unchanged.
```yaml
service:
  port: 7897
  enabled: true
```
````

真实输出：

````text
保持此配置不变 。
```yaml
service:
  port: 7897
  enabled: true
```
````


## 19. 中英混合技术说明（中文 → 英文）

原文：

````text
请检查 Rust 项目的 API 返回值，并保留 user_id 和 getStatus。
````

真实输出：

````text
Please check the Rust project API return value and keep user_id and getStatus.
````


## 20. 长段落说明（英文 → 中文）

原文：

````text
The application reads account status from a local cache. After a completed conversation, it refreshes quota information through the configured proxy. Translation runs locally and does not send the source text to a public translation service. Keep the original response available so the user can compare it with the translated version.
````

真实输出：

````text
应用程序从本地缓存读取账户状态 。 在完成对话后,它通过配置的代理更新配额信息. 翻译在当地运行,不向公共翻译服务发送源文本. 保留原有的响应可用,以便用户可以将其与翻译版本进行比较.
````


## 21. 纯代码无需翻译（英文 → 中文）

原文：

````text
```python
print("你好")
```
````

真实输出：

````text
```python
print("你好")
```
````


## 22. 纯标点无需翻译（中文 → 英文）

原文：

````text
！？。……
````

真实输出：

````text
！？。……
````


## 23. 中文原文占位符同名标识符（中文 → 英文）

原文：

````text
说明 CCAM0 和 ZXQ1 的用途，保留 `getStatus`。
````

真实输出：

````text
Description of CCAM0 and ZXQ1 uses, retain `getStatus`.
````


## 24. 英文原文占位符同名标识符（英文 → 中文）

原文：

````text
Compare CCAM0 with ZXQ1 and keep `user_id` unchanged.
````

真实输出：

````text
将CCAM0与ZXQ1比较,保持`user_id`不变.
````


## 25. 中文单符免译（中文 → 英文）

原文：

````text
请保留 ～这个产品叫鹦鹉～，并解释安装步骤。
````

真实输出：

````text
Please retain 这个产品叫鹦鹉 and explain the installation steps.
````


## 26. 中文双符免译（中文 → 英文）

原文：

````text
请解释这个项目，保留 ～～不要翻译这段内容～～。
````

真实输出：

````text
Please explain this project and keep 不要翻译这段内容.
````


## 27. 多行免译（中文 → 英文）

原文：

````text
请解释 ～第一行保持中文
第二行保留 user_id 和 `cargo test`～ 的用途。
````

真实输出：

````text
Please explain the use of 第一行保持中文
第二行保留 user_id 和 `cargo test`.
````


## 28. 多段免译与代码和链接（中文 → 英文）

原文：

````text
保留 ～产品名称～ 和 ～～精确中文说明～～，检查 `src/main.rs` 并参考 https://example.test/docs。
````

真实输出：

````text
Keep 产品名称 and 精确中文说明, check `src/main.rs` and refer to https://example.test/docs。
````


## 29. 未闭合单符保护至末尾（中文 → 英文）

原文：

````text
请解释这个项目。～后续不翻译
包括 `main.rs` 和最后一行。
````

真实输出：

````text
Please explain this project.后续不翻译
包括 `main.rs` 和最后一行。
````


## 30. 未闭合双符保护至末尾（英文 → 中文）

原文：

````text
Explain the project. ～～Keep this exact English.
Do not translate the remaining text.
````

真实输出：

````text
解释一下项目 Keep this exact English.
Do not translate the remaining text.
````


## 31. 代码中的孤立全角符不影响后文（中文 → 英文）

原文：

````text
```rust
let label = "～不闭合";
let id = "CCAM0 ZXQ1";
```
请解释这个函数，不要修改文件。
````

真实输出：

````text
```rust
let label = "～不闭合";
let id = "CCAM0 ZXQ1";
```
Please explain this function and do not modify the file.
````


## 32. 表格内免译与竖线（中文 → 英文）

原文：

````text
| 内容 | 状态 |
| --- | --- |
| ～甲|乙～ | 需要检查 |
````

真实输出：

````text
| Contents | Status |
| --- | --- |
| 甲|乙 | Needs check |
````


## 33. 免译内原占位符和标识符（英文 → 中文）

原文：

````text
Keep ～CCAM0 ZXQ1 `user_id`～ unchanged and explain the steps.
````

真实输出：

````text
保持CCAM0 ZXQ1 `user_id`不变并解释步骤.
````


## 34. 紧邻正文与连续免译段（英文 → 中文）

原文：

````text
Keep～甲～～乙～and～～丙～～unchanged.
````

真实输出：

````text
保持甲 乙和丙不变.
````


## 35. 整段免译仅去除外层标记（中文 → 英文）

原文：

````text
～～中文无需翻译
English stays exact.
`cargo test`～～
````

真实输出：

````text
中文无需翻译
English stays exact.
`cargo test`
````


## 36. 中文说明保留英文项目名（中文 → 英文）

原文：

````text
请分析 ～parrot-ai-server-rust～ 项目，不要修改文件。
````

真实输出：

````text
Please analyse parrot-ai-server-rust items and do not modify files.
````


## 37. 英文说明保留英文项目名（英文 → 中文）

原文：

````text
Explain ～parrot-ai-server-rust～ without changing its files.
````

真实输出：

````text
解释parrot-ai-server-rust而不更改其文件.
````


## 38. 仅英文项目名免译（中文 → 英文）

原文：

````text
～parrot-ai-server-rust～
````

真实输出：

````text
parrot-ai-server-rust
````


## 39. 英文正文只剥离双层标记（中文 → 英文）

原文：

````text
  Inspect ～～parrot-ai-server-rust～～ only.
````

真实输出：

````text
  Inspect parrot-ai-server-rust only.
````


## 40. 代码中的符号保留、项目名的符号移除（中文 → 英文）

原文：

````text
Read `～literal～` in ～parrot-ai-server-rust～.
````

真实输出：

````text
Read `～literal～` in parrot-ai-server-rust.
````


## 41. 反向纯免译英文项目名（英文 → 中文）

原文：

````text
～～parrot-ai-server-rust～～
````

真实输出：

````text
parrot-ai-server-rust
````


## 42. 长技术回复：表格与大量代码标识符（英文 → 中文）

原文：

````text
# Review summary

| Component | Status |
| --- | --- |
| `module_0.rs` | Check the changes in `commit_0` before deployment. |
| `module_1.rs` | Check the changes in `commit_1` before deployment. |
| `module_2.rs` | Check the changes in `commit_2` before deployment. |
| `module_3.rs` | Check the changes in `commit_3` before deployment. |
| `module_4.rs` | Check the changes in `commit_4` before deployment. |
| `module_5.rs` | Check the changes in `commit_5` before deployment. |
| `module_6.rs` | Check the changes in `commit_6` before deployment. |
| `module_7.rs` | Check the changes in `commit_7` before deployment. |
| `module_8.rs` | Check the changes in `commit_8` before deployment. |
| `module_9.rs` | Check the changes in `commit_9` before deployment. |
| `module_10.rs` | Check the changes in `commit_10` before deployment. |
| `module_11.rs` | Check the changes in `commit_11` before deployment. |
| `module_12.rs` | Check the changes in `commit_12` before deployment. |
| `module_13.rs` | Check the changes in `commit_13` before deployment. |
| `module_14.rs` | Check the changes in `commit_14` before deployment. |
| `module_15.rs` | Check the changes in `commit_15` before deployment. |

## Next steps

- Inspect `src/module_0.rs`, run `cargo test module_0`, and keep configuration unchanged.
- Inspect `src/module_1.rs`, run `cargo test module_1`, and keep configuration unchanged.
- Inspect `src/module_2.rs`, run `cargo test module_2`, and keep configuration unchanged.
- Inspect `src/module_3.rs`, run `cargo test module_3`, and keep configuration unchanged.
- Inspect `src/module_4.rs`, run `cargo test module_4`, and keep configuration unchanged.
- Inspect `src/module_5.rs`, run `cargo test module_5`, and keep configuration unchanged.
- Inspect `src/module_6.rs`, run `cargo test module_6`, and keep configuration unchanged.
- Inspect `src/module_7.rs`, run `cargo test module_7`, and keep configuration unchanged.
- Inspect `src/module_8.rs`, run `cargo test module_8`, and keep configuration unchanged.
- Inspect `src/module_9.rs`, run `cargo test module_9`, and keep configuration unchanged.
- Inspect `src/module_10.rs`, run `cargo test module_10`, and keep configuration unchanged.
- Inspect `src/module_11.rs`, run `cargo test module_11`, and keep configuration unchanged.
- Inspect `src/module_12.rs`, run `cargo test module_12`, and keep configuration unchanged.
- Inspect `src/module_13.rs`, run `cargo test module_13`, and keep configuration unchanged.
- Inspect `src/module_14.rs`, run `cargo test module_14`, and keep configuration unchanged.
- Inspect `src/module_15.rs`, run `cargo test module_15`, and keep configuration unchanged.

```rust
fn main() { println!("hello"); }
```
````

真实输出：

````text
# 审查摘要

| 构成部分 | 状态 |
| --- | --- |
| `module_0.rs` | 部署前请检查`commit_0`的变化. |
| `module_1.rs` | 部署前请检查`commit_1`的变化. |
| `module_2.rs` | 在部署前检查`commit_2`的变化. |
| `module_3.rs` | 部署前请检查`commit_3`的变化. |
| `module_4.rs` | 部署前请检查`commit_4`的变化. |
| `module_5.rs` | 部署前请检查`commit_5`的变化. |
| `module_6.rs` | 在部署前检查`commit_6`的变化. |
| `module_7.rs` | 部署前请检查`commit_7`的变化. |
| `module_8.rs` | 部署前请检查`commit_8`的变化. |
| `module_9.rs` | 部署前请检查`commit_9`中的变化. |
| `module_10.rs` | 部署前请检查`commit_10`的变化. |
| `module_11.rs` | 部署前请检查`commit_11`的变化. |
| `module_12.rs` | 在部署前检查`commit_12`的变化. |
| `module_13.rs` | 部署前请检查`commit_13`的变化. |
| `module_14.rs` | 部署前请检查`commit_14`的变化. |
| `module_15.rs` | 部署前请检查`commit_15`的变化. |

## 今后的步骤

- 检查`src/module_0.rs`,运行`cargo test module_0`,配置不变.
- 检查`src/module_1.rs`,运行`cargo test module_1`,配置不变.
- 检查`src/module_2.rs`,运行`cargo test module_2`,配置不变.
- 检查`src/module_3.rs`,运行`cargo test module_3`,配置不变.
- 检查`src/module_4.rs`,运行`cargo test module_4`,配置不变.
- 检查`src/module_5.rs`,运行`cargo test module_5`,配置不变.
- 检查`src/module_6.rs`,运行`cargo test module_6`,配置不变.
- 检查`src/module_7.rs`,运行`cargo test module_7`,配置不变.
- 检查`src/module_8.rs`,运行`cargo test module_8`,配置不变.
- 检查`src/module_9.rs`,运行`cargo test module_9`,保持配置不变.
- 检查`src/module_10.rs`,运行`cargo test module_10`,配置不变.
- 检查`src/module_11.rs`,运行`cargo test module_11`,保持配置不变.
- 检查`src/module_12.rs`,运行`cargo test module_12`,配置不变.
- 检查`src/module_13.rs`,运行`cargo test module_13`,配置不变.
- 检查`src/module_14.rs`,运行`cargo test module_14`,配置不变.
- 检查`src/module_15.rs`,运行`cargo test module_15`,配置不变.

```rust
fn main() { println!("hello"); }
```
````
