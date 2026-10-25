# 本机中英翻译

## 视觉方向

延续 CCAM 的现代黑工作台，翻译属于对话内容，设置不占据独立工具栏。中文输入、英文执行、中文阅读之间的转换必须可见、可取消，原文始终保留。

- 背景 `#111111`，输入面 `#1C1C1C`，边界 `#303030`。
- 正文 `#F5F5F5`，次要文字 `#A3A3A3`，成功反馈 `#82D7B4`；失败沿用主题警示色。
- 使用系统字体：正文 15pt / 22pt 行高，控件 12–13pt，来源说明 10–11pt。数字才使用等宽字宽。
- 内容左对齐，沿用 760pt 最大正文宽度；回复操作位于对应回复底部，图标点击区至少 28pt。

```text
原始中文消息                         [查看已发送英文]

中文译文（自动模式）
                               [翻译 / 查看原文图标]

┌ 中文输入，翻译失败保留草稿 ──────────────────────┐
│                                               │
│ 中文输入                         [中→EN 菜单] │
│ [附件] [模型] [思考强度] [权限模式]      [发送] │
└───────────────────────────────────────────────┘
```

翻译菜单包含“中文输入译成英文”和“自动显示中文”。自动模式在回复输出过程中按完整句段增量显示中文，原英文可切换查看；手动模式通过回复底部图标按需展开译文。长回复翻译只影响阅读，不阻塞项目任务或改变 Claude 会话。

## 对照需求的取舍

不增加独立翻译页面、彩色卡片或语言选择器。这里是中英编程工作流，固定两个方向比通用翻译软件的多语言表单更清楚。沿用用户指定的黑色和原有字体，不引入新的装饰色。请求过程中不自动改变输入文字；翻译失败时不能偷偷发送原文。

## 数据与执行

采用 Argos Translate 的中英模型及 CTranslate2 本机推理。模型初次准备需要下载；翻译本身不调用 Claude、不访问公共翻译服务。代码块、行内代码和路径保留。用户中文原文与实际发送英文分开保存；回复中文译文只存在 CCAM 本地记录中，不改写原生会话上下文。

中文全角波浪号 `～内容～` 和 `～～内容～～` 表示免翻译区域，支持多段、跨行；区域内的文字不送入翻译模型，结果移除包裹符。纯英文输入也处理标记；未闭合时移除开头标记并保留后面的全部内容。代码内的波浪号仍保持原样。用法放在翻译按钮的悬浮提示中，不增加常驻控件。

每轮问答结束后独立查询 CCAM 的额度接口，沿用当前代理；不发送探测模型消息。启动、周期刷新和手动缓存刷新继续使用已有本机记录。失败保留旧值并显示状态，不把未知或失败当成满额。

## 验收

检查桌面和窄分屏下的控件、键盘焦点、发送前取消、翻译失败草稿保留、跨对话回调隔离、原文切换和自动翻译；以本机中英模型做真实翻译样例，本轮不进行联网模型会话测试；代理恢复后再单独验证真实问答和额度接口。

## 长回复恢复与富文本

先批量推理，再逐段校验保护标记。失败段使用局部低编号标记重试，仍失败时仅翻译标记之间的自然语言，将免译内容原样拼接回来。完整结果再次校验。工作进程通过 JSON 错误码区分保护失败、单段过长、空结果和组件缺失，不将内部异常、路径或文本显示给用户。

`ChatMarkdownView` 使用原生 AppKit 渲染正文和译文，代码复用 `CodeHighlighter`。表格独立水平滚动，工具输出保持纯文本。无 WebView、脚本执行或自动图片下载；普通链接仅接受 HTTP、HTTPS 和 mailto。

## Native Hy-MT2 backend

`native.json` is a small pointer in the existing application support translation directory. Model weights, pinned llama.cpp runtime and original licenses live in the user-selected folder, including external drives. Readiness validates the pointer and required files. Selecting native disables legacy fallback; an unmounted drive is surfaced to the user.

A standard-library Python worker shields protected spans, keeps paragraph context (bounded chunks), applies a context-aware technical glossary and validates literal counts before restoring exact originals. Each request owns one native Metal server, bound to a randomly selected loopback port with a random API key. Redirects and environment proxies are disabled for inference; the runtime is started with `--offline --no-webui`. A private process group lets cancellation/timeout terminate both worker and server. No persistent service, Docker engine or cloud translation is used.

Installation uses pinned SHA-256 artifacts and validates inference before atomically changing the active pointer. The UI keeps drafts and originals on failure. Cached translations are changed only by explicit retranslation or newly completed replies. Copying a reply always copies the original Markdown source, irrespective of which language is currently displayed.

### Native desktop verification (2.9.0 / 26)

On an Apple M4 with 32 GB memory, the installed application successfully validated the external-drive model using the production Metal launch path and retranslated an existing long reply. The original-copy button pasted the complete English Markdown into an empty draft; the draft was then cleared without sending. Reply controls and rich-text rendering were inspected in the actual desktop window. Model and runtime checksums were verified during installation.

The opt-in regression corpus contains 47 real local translations; exact outputs, CPU test timings and the scope of structural/terminology checks are recorded in `NATIVE_TRANSLATION_EXAMPLES.md`. Additional checks cover 474 offline UI assertions, 30 translation-service assertions and 8 native-adapter tests. Foundation.Process's existing private process group is accepted without calling setsid twice. No Claude inference requests were made during this verification. Translation remains an aid: especially with ambiguous prose, a small model can still choose the wrong word or grammatical role, so the English original is retained.


## Streaming translation and remembered approvals (2.10)

`StreamingReplyTranslation` buffers incomplete fenced/inline code, tables and no-translate spans. It debounces updates and serially translates stable suffixes, preserving whitespace between chunks. Source replacements cancel stale work. A completion signal also commits an already-translated source with no remaining suffix. Preview state is never written as transcript content; errors fall back to the original and do not cause retry loops. The view stops translating intermediate narration once subsequent tools identify it as execution detail.

Permission memory is a separate atomic, mode-0600 document beside the project chat document. Rules contain exact tool names, project ID and canonical-directory checks, not commands or credentials. The checkbox explicitly grants subsequent calls of that tool within this project, including different inputs. Each reused grant still passes the live request, generation and session-identity validation. Plan mode and questions are excluded. The mode menu clears remembered grants. This does not set global CLI bypass flags.
