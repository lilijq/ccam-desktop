# 本地翻译真实样例验收

这份记录由现有本地模型实际执行生成；未调用 Claude、公共翻译接口，也未下载任何内容。

共 24 个样例通过自动检查。引擎为 CTranslate2 4.4.0 / SentencePiece 0.2.0，使用 Argos Translate 1.9 中英双向模型，CPU int8、beam 4。

自动检查覆盖：非空输出、目标语言字符、代码/命令/标识符/路径/URL 的精确保留与出现次数、Markdown 标题列表及表格结构、纯代码和纯标点不变，以及选定句子的否定词保留。这些检查不等于语义完全准确；下方保留每一次真实输出，未人工润色。

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

Worker SHA-256：`9c80519f856b0149bb7fc082d8190e64a2d4948e6ab149f2565f204d3a736c69`


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
