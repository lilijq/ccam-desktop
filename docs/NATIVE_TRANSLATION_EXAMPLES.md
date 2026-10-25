# Hy-MT2 原生翻译实测

模型：Tencent Hy-MT2-1.8B Q8_0；运行时：llama.cpp b11871。模型与运行时均已校验官方 SHA-256。
测试设备：Apple M4 / 32 GB；本次设备后端：CPU（测试沙盒无法访问 Metal）。
只请求本机回环地址，无 Claude 或公共翻译 API 请求。复用一个本机模型进程逐条翻译；时间不包含模型首次加载，不能视作聊天端到端延迟。
47/47 个样例通过结构、免译内容、指定术语及否定词检查。自动检查不证明任意文本语义完全准确；以下为未经润色的真实输出。

代码与免译内容在模型输入前隔离，输出后校验恢复。保护失败时保留原文并允许重试。

## negative_zh · 中文禁止修改

耗时：0.65 秒；检查：通过

原文：
````text
请检查这个项目，不要修改任何文件。
````
输出：
````text
Please check this project without modifying any files.
````

## negative_en · 英文禁止修改

耗时：0.58 秒；检查：通过

原文：
````text
Inspect this project. Do not modify any files.
````
输出：
````text
检查该项目。不要修改任何文件。
````

## rust_zh · Rust 代码块

耗时：0.32 秒；检查：通过

原文：
````text
请解释这段代码，不要修改它。
```rust
fn main() { println!("你好"); }
```

````
输出：
````text
Please explain this code without modifying it.
```rust
fn main() { println!("你好"); }
```

````

## swift_en · Swift 代码块

耗时：0.26 秒；检查：通过

原文：
````text
This function returns a greeting.
```swift
func greet() -> String { "hello" }
```

````
输出：
````text
此函数返回一个问候语。
```swift
func greet() -> String { "hello" }
```

````

## python_zh · Python 代码块

耗时：0.36 秒；检查：通过

原文：
````text
解释下面的函数，并给出测试建议。
```python
def add(a, b):
    return a + b
```

````
输出：
````text
Explain the following function and provide testing suggestions.
```python
def add(a, b):
    return a + b
```

````

## inline_zh · 中文多段行内代码

耗时：0.68 秒；检查：通过

原文：
````text
请检查 `src/main.rs` 的错误，运行 `cargo test`，不要改动配置文件。
````
输出：
````text
Check the errors for `src/main.rs`, run `cargo test` without modifying the configuration file.
````

## inline_en · 英文多个标识符

耗时：0.6 秒；检查：通过

原文：
````text
Call `getStatus()` with `user_id` and inspect `result.value`.
````
输出：
````text
使用 `user_id` 调用 `getStatus()`，并检查 `result.value`。
````

## url_zh · 中文带查询参数 URL

耗时：0.39 秒；检查：通过

原文：
````text
请参考 https://example.test/docs?q=rust&lang=en#usage 并说明步骤。
````
输出：
````text
Refer to https://example.test/docs?q=rust&lang=en#usage and explain the steps.
````

## url_en · 英文带查询参数 URL

耗时：0.32 秒；检查：通过

原文：
````text
See https://example.test/docs?q=rust&lang=en#usage for the steps.
````
输出：
````text
有关步骤，请参阅 https://example.test/docs?q=rust&lang=en#usage。
````

## windows_zh · Windows 路径

耗时：0.36 秒；检查：通过

原文：
````text
读取 C:\work\app\main.rs 并说明错误。
````
输出：
````text
Read C:\work\app\main.rs and explain the error.
````

## unix_en · Unix 与用户目录路径

耗时：0.57 秒；检查：通过

原文：
````text
Read /tmp/demo.json and ~/app/src/main.rs without changing either file.
````
输出：
````text
在不修改任何文件的情况下读取 /tmp/demo.json 和 ~/app/src/main.rs。
````

## shell_zh · Git 命令与参数

耗时：0.4 秒；检查：通过

原文：
````text
运行 `git diff --stat -- src/main.rs`，只查看变化。
````
输出：
````text
Run `git diff --stat -- src/main.rs` and only observe the changes.
````

## shell_en · 未加反引号的命令

耗时：0.58 秒；检查：通过

原文：
````text
Run git status --short before making changes.
````
输出：
````text
在进行更改之前，请先运行 git status 和 --short。
````

## heading_zh · 中文标题与列表

耗时：1.22 秒；检查：通过

原文：
````text
# 检查步骤

- 读取文件。
- 运行测试。

## 注意事项
不要提交改动。
````
输出：
````text
# Inspection Steps

- Read the file.
- Run the test.

## Notes
Do not commit changes.
````

## heading_en · 英文标题与编号列表

耗时：1.18 秒；检查：通过

原文：
````text
# Review steps

1. Read the files.
2. Run the tests.

## Notes
Do not commit changes.
````
输出：
````text
# 审核步骤

1. 阅读文件。
2. 运行测试。

## 注意事项
请勿提交更改。
````

## table_en · Markdown 表格

耗时：0.69 秒；检查：通过

原文：
````text
| File | Status |
| --- | --- |
| `src/main.rs` | Ready for review |

````
输出：
````text
| 文件 | 状态 |
| --- | --- |
| `src/main.rs` | 已准备好审核 |

````

## json_zh · JSON 配置代码块

耗时：0.15 秒；检查：通过

原文：
````text
说明这个配置。
```json
{"name":"demo","enabled":true}
```

````
输出：
````text
Explain this configuration.
```json
{"name":"demo","enabled":true}
```

````

## yaml_en · YAML 配置代码块

耗时：0.18 秒；检查：通过

原文：
````text
Keep this configuration unchanged.
```yaml
service:
  port: 7897
  enabled: true
```

````
输出：
````text
保持此配置不变。
```yaml
service:
  port: 7897
  enabled: true
```

````

## mixed_zh · 中英混合技术说明

耗时：0.61 秒；检查：通过

原文：
````text
请检查 Rust 项目的 API 返回值，并保留 user_id 和 getStatus。
````
输出：
````text
Check the API return values of the Rust project and keep user_id and getStatus.
````

## long_en · 长段落说明

耗时：1.57 秒；检查：通过

原文：
````text
The application reads account status from a local cache. After a completed conversation, it refreshes quota information through the configured proxy. Translation runs locally and does not send the source text to a public translation service. Keep the original response available so the user can compare it with the translated version.
````
输出：
````text
该应用程序从本地缓存中读取账户状态。完成对话后，它会通过配置的代理服务器刷新配额信息。翻译在本地进行，不会将源文本发送到公共翻译服务。保留原始响应，以便用户可以将其与翻译版本进行比较。
````

## codeonly · 纯代码无需翻译

耗时：0.0 秒；检查：通过

原文：
````text
```python
print("你好")
```

````
输出：
````text
```python
print("你好")
```

````

## punctuation · 纯标点无需翻译

耗时：0.0 秒；检查：通过

原文：
````text
！？。……
````
输出：
````text
！？。……
````

## collisions_zh · 中文原文占位符同名标识符

耗时：0.63 秒；检查：通过

原文：
````text
说明 CCAM0 和 ZXQ1 的用途，保留 `getStatus`。
````
输出：
````text
Explain the purpose of CCAM0 and ZXQ1, and retain `getStatus`.
````

## collisions_en · 英文原文占位符同名标识符

耗时：0.6 秒；检查：通过

原文：
````text
Compare CCAM0 with ZXQ1 and keep `user_id` unchanged.
````
输出：
````text
将 CCAM0 与 ZXQ1 进行比较，并保持 `user_id` 不变。
````

## fullwidth_single_zh · 中文单符免译

耗时：0.36 秒；检查：通过

原文：
````text
请保留 ～这个产品叫鹦鹉～，并解释安装步骤。
````
输出：
````text
Please keep 这个产品叫鹦鹉 and explain the installation steps.
````

## fullwidth_double_zh · 中文双符免译

耗时：0.35 秒；检查：通过

原文：
````text
请解释这个项目，保留 ～～不要翻译这段内容～～。
````
输出：
````text
Please explain this project, keeping 不要翻译这段内容 intact.
````

## fullwidth_multiline_zh · 多行免译

耗时：0.29 秒；检查：通过

原文：
````text
请解释 ～第一行保持中文
第二行保留 user_id 和 `cargo test`～ 的用途。
````
输出：
````text
Please explain the purpose of 第一行保持中文
第二行保留 user_id 和 `cargo test`.
````

## fullwidth_multiple_zh · 多段免译与代码和链接

耗时：0.67 秒；检查：通过

原文：
````text
保留 ～产品名称～ 和 ～～精确中文说明～～，检查 `src/main.rs` 并参考 https://example.test/docs。
````
输出：
````text
Keep 产品名称 and 精确中文说明, check `src/main.rs`, and refer to https://example.test/docs。.
````

## fullwidth_unclosed_zh · 未闭合单符保护至末尾

耗时：0.26 秒；检查：通过

原文：
````text
请解释这个项目。～后续不翻译
包括 `main.rs` 和最后一行。
````
输出：
````text
Please explain this project. 后续不翻译
包括 `main.rs` 和最后一行。
````

## fullwidth_unclosed_double_en · 未闭合双符保护至末尾

耗时：0.21 秒；检查：通过

原文：
````text
Explain the project. ～～Keep this exact English.
Do not translate the remaining text.
````
输出：
````text
解释该项目。Keep this exact English.
Do not translate the remaining text.
````

## fullwidth_code_boundary_zh · 代码中的孤立全角符不影响后文

耗时：0.3 秒；检查：通过

原文：
````text
```rust
let label = "～不闭合";
let id = "CCAM0 ZXQ1";
```
请解释这个函数，不要修改文件。
````
输出：
````text
```rust
let label = "～不闭合";
let id = "CCAM0 ZXQ1";
```
Please explain this function without modifying the file.
````

## fullwidth_table_zh · 表格内免译与竖线

耗时：0.59 秒；检查：通过

原文：
````text
| 内容 | 状态 |
| --- | --- |
| ～甲|乙～ | 需要检查 |

````
输出：
````text
| Content | Status |
| --- | --- |
| 甲|乙 | Needs verification |

````

## fullwidth_markers_en · 免译内原占位符和标识符

耗时：0.37 秒；检查：通过

原文：
````text
Keep ～CCAM0 ZXQ1 `user_id`～ unchanged and explain the steps.
````
输出：
````text
保持 CCAM0 ZXQ1 `user_id` 不变，并解释步骤。
````

## fullwidth_adjacent_en · 紧邻正文与连续免译段

耗时：0.5 秒；检查：通过

原文：
````text
Keep～甲～～乙～and～～丙～～unchanged.
````
输出：
````text
保持 甲、乙 和 丙 不变。
````

## fullwidth_only_zh · 整段免译仅去除外层标记

耗时：0.0 秒；检查：通过

原文：
````text
～～中文无需翻译
English stays exact.
`cargo test`～～
````
输出：
````text
中文无需翻译
English stays exact.
`cargo test`
````

## fullwidth_project_name_zh · 中文说明保留英文项目名

耗时：0.41 秒；检查：通过

原文：
````text
请分析 ～parrot-ai-server-rust～ 项目，不要修改文件。
````
输出：
````text
Please analyze the parrot-ai-server-rust project without modifying the file.
````

## fullwidth_project_name_en · 英文说明保留英文项目名

耗时：0.33 秒；检查：通过

原文：
````text
Explain ～parrot-ai-server-rust～ without changing its files.
````
输出：
````text
在不更改其文件的情况下解释 parrot-ai-server-rust。
````

## fullwidth_project_name_only_zh · 仅英文项目名免译

耗时：0.0 秒；检查：通过

原文：
````text
～parrot-ai-server-rust～
````
输出：
````text
parrot-ai-server-rust
````

## fullwidth_english_only_zh · 英文正文只剥离双层标记

耗时：0.0 秒；检查：通过

原文：
````text
  Inspect ～～parrot-ai-server-rust～～ only.

````
输出：
````text
  Inspect parrot-ai-server-rust only.

````

## fullwidth_code_and_name_zh · 代码中的符号保留、项目名的符号移除

耗时：0.0 秒；检查：通过

原文：
````text
Read `～literal～` in ～parrot-ai-server-rust～.
````
输出：
````text
Read `～literal～` in parrot-ai-server-rust.
````

## fullwidth_project_name_only_en · 反向纯免译英文项目名

耗时：0.0 秒；检查：通过

原文：
````text
～～parrot-ai-server-rust～～
````
输出：
````text
parrot-ai-server-rust
````

## long_review_en · 长技术回复：表格与大量代码标识符

耗时：19.26 秒；检查：通过

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
输出：
````text
# 评审总结

| 组件 | 状态 |
| --- | --- |
| `module_0.rs` | 在部署前检查 `commit_0` 的变更。 |
| `module_1.rs` | 在部署前检查 `commit_1` 的变更。 |
| `module_2.rs` | 在部署前检查 `commit_2` 的变更。 |
| `module_3.rs` | 在部署前检查 `commit_3` 的变更。 |
| `module_4.rs` | 在部署前检查 `commit_4` 的变更。 |
| `module_5.rs` | 在部署前检查 `commit_5` 的变更。 |
| `module_6.rs` | 在部署前检查 `commit_6` 的变更。 |
| `module_7.rs` | 在部署前检查 `commit_7` 的变更。 |
| `module_8.rs` | 在部署前检查 `commit_8` 的变更。 |
| `module_9.rs` | 在部署前检查 `commit_9` 的变更。 |
| `module_10.rs` | 在部署前检查 `commit_10` 的变更。 |
| `module_11.rs` | 在部署前检查 `commit_11` 的变更。 |
| `module_12.rs` | 在部署前检查 `commit_12` 的变更。 |
| `module_13.rs` | 在部署前检查 `commit_13` 的变更。 |
| `module_14.rs` | 在部署前检查 `commit_14` 的变更。 |
| `module_15.rs` | 在部署前检查 `commit_15` 的变更。 |

## 下一步行动

- 检查 `src/module_0.rs`，运行 `cargo test module_0`，并保持配置不变。
- 检查 `src/module_1.rs`，运行 `cargo test module_1`，并保持配置不变。
- 检查 `src/module_2.rs`，运行 `cargo test module_2`，并保持配置不变。
- 检查 `src/module_3.rs`，运行 `cargo test module_3`，并保持配置不变。
- 检查 `src/module_4.rs`，运行 `cargo test module_4`，并保持配置不变。
- 检查 `src/module_5.rs`，运行 `cargo test module_5`，并保持配置不变。
- 检查 `src/module_6.rs`，运行 `cargo test module_6`，并保持配置不变。
- 检查 `src/module_7.rs`，运行 `cargo test module_7`，并保持配置不变。
- 检查 `src/module_8.rs`，运行 `cargo test module_8`，并保持配置不变。
- 检查 `src/module_9.rs`，运行 `cargo test module_9`，并保持配置不变。
- 检查 `src/module_10.rs`，运行 `cargo test module_10`，并保持配置不变。
- 检查 `src/module_11.rs`，运行 `cargo test module_11`，并保持配置不变。
- 检查 `src/module_12.rs`，运行 `cargo test module_12`，并保持配置不变。
- 检查 `src/module_13.rs`，运行 `cargo test module_13`，并保持配置不变。
- 检查 `src/module_14.rs`，运行 `cargo test module_14`，并保持配置不变。
- 检查 `src/module_15.rs`，运行 `cargo test module_15`，并保持配置不变。

```rust
fn main() { println!("hello"); }
```

````

## technical_context · Git 术语与条件

耗时：1.26 秒；检查：通过

原文：
````text
The repository contains three commits on the feature branch. Resolve the merge conflict before deployment. Do not deploy until all tests pass.
````
输出：
````text
该仓库在功能分支上有三个提交。在部署前解决合并冲突。在所有测试通过之前不要进行部署。
````

## concurrency · 并发术语

耗时：1.09 秒；检查：通过

原文：
````text
The callback may cause a race condition. Use idempotency to prevent duplicate refunds. A database migration must not introduce a deadlock.
````
输出：
````text
回调可能会导致竞态条件。使用幂等性来防止重复退款。数据库迁移不得引入死锁。
````

## technical_zh · 中文技术任务

耗时：1.24 秒；检查：通过

原文：
````text
请检查 ～parrot-ai-server-rust～ 仓库的提交与分支，不要执行部署。先解决合并冲突，再运行 `cargo test`。
````
输出：
````text
Check the commits and branches in the parrot-ai-server-rust repository. Do not perform deployment. First, resolve the merge conflicts, then run `cargo test`.
````

## business_context · 业务与代码混合

耗时：1.08 秒；检查：通过

原文：
````text
At checkout, validate the stock before creating a refund. Keep `order_id` unchanged and do not log the access token.
````
输出：
````text
结账时，在申请退款前先验证库存情况。保持 `order_id` 不变，不要记录访问令牌。
````

## engineering_ambiguity · 软件维护多义词

耗时：1.57 秒；检查：通过

原文：
````text
Start on the housekeeping by reconciling the app branch. The remote commit `abc1234` changes the 3D viewer. Verify stock holds during acceptance before rollout.
````
输出：
````text
首先进行清理维护，整合应用分支。远程提交 `abc1234` 会修改 3D 查看器。在发布前，在验收过程中确认库存预留情况。
````
