# 架构

CCAM Desktop 是本地 Swift/AppKit 客户端。它调用用户安装的 CCAM 和 Claude Code，使用原生视图处理聊天、文件、Git 和终端；没有网页服务器或额外的云端账户后台。

| 层 | 主要文件 | 职责 |
| --- | --- | --- |
| 界面 | `App.swift`、`WorkspaceSidebar.swift`、`Theme.swift` | 项目导航、左下管理菜单、外观 |
| 项目 | `ProjectStore.swift`、`ProjectWorkspace.swift`、`WorkspacePanes.swift` | 项目目录、归档、可持久化分屏布局与各项目视图 |
| 聊天 | `ChatStore.swift`、`ChatRuntime.swift`、`ProjectChatView.swift` | 本地历史、草稿、流式输出和精确会话恢复 |
| 账号池 | `GlobalPool.swift`、`PoolCoordinator.swift` | 根据账号额度选用账号，在明确额度事件后接续 |
| 浏览器资料 | `BrowserLockStore.swift`、`BrowserRouting.swift`、`BrowserSettingsGuard.swift` | Chrome 资料选择、登录路由与配置冲突检查 |
| 文件与 Git | `ProjectFiles.swift`、`CodeEditor.swift`、`ProjectFilePreview.swift`、`ProjectGit.swift`、`GitRepositoryDiscovery.swift` | 目录树、语言着色、文件草稿与预览、多仓库选择、差异与暂存/提交 |
| 终端 | `PTYSession.swift`、`PTYBridge.c`、`TerminalWorkspace.swift` | 进程生命周期、PTY 和 SwiftTerm 渲染 |

## 会话与账号

项目保存工作目录、草稿和会话上下文。账号额度在全局账号池中管理，项目不绑定固定额度。一次运行记录原生会话身份；只有明确的额度耗尽事件触发换号。下一账号恢复精确会话，保留目录与成果，不重复执行最初提示词。普通错误和停止操作不会触发换号。

普通追问继续使用原账号及原会话。没有可接续的账号时，已开始的任务可等待额度恢复或取消；首次启动就没有可用账号会报错。聊天使用双向 stream-json 控制通道接收权限请求；用户可一次批准或记住本项目的工具权限，也可拒绝、回答问题或确认计划。记住的权限不跨项目，不跳过计划模式。请求绑定运行代次、请求 ID 与已验证的会话身份，停止与换号后旧审批失效。

移交终端后仍可编写聊天草稿。“返回聊天”等待关联 PTY 退出，再使用原身份或 SessionStart 验证的新身份恢复；未验证的账号切换不能猜测恢复目标。

`ExecutionProxy` 在可能联网的 CCAM 操作、聊天和终端启动前解析当前代理。缺失或无效配置会抛出错误，不启动子进程；账号清单和明确的缓存读取保持离线可用。开发终端使用临时隔离的 ZDOTDIR 固定代理环境，不执行个人 shell 启动文件。该策略不是系统级网络防火墙。

`LocalTranslator` 默认升级到隔离的 Python / llama.cpp 进程，通过本机认证回环服务使用 Hy-MT2 与 Metal；未升级的安装保留 Argos 兼容路径。输入翻译完成后才调用聊天运行器，取消、编辑或切换对话会丢弃旧回调。回复译文按消息 ID 与原文校验后单独保存，原英文和中文草稿不互相覆盖；翻译进程不继承账号或代理环境。初次安装是独立的显式操作。

真实聊天进程结束后发出一次 `onTurnFinished`，自动换号接续期间不重复发出。账号刷新队列合并并发完成事件，使用 CCAM 的 `live` 额度接口与现有代理；界面重绘、翻译、启动失败和定时缓存刷新不会触发联网查额。

## 数据位置

应用数据默认位于 `~/Library/Application Support/CCAM Desktop/`，包括项目列表、Chrome 资料绑定和按项目保存的聊天记录。凭据、额度缓存与原生历史由 CCAM / Claude Code 管理。

`CCAM_DESKTOP_DATA_DIR`、`CCAM_HOME` 和 `CCAM_EXECUTABLE` 可用于隔离测试。不要将真实凭据或本机数据目录提交到仓库。

每个项目的窗格布局与拖动比例保存在本机偏好设置中。每个对话按 conversation ID 绑定唯一真实视图与运行器，工具类型各保留一个真实视图；调整、关闭、聚焦窗格只改变视图位置，不复制聊天运行器或终止 PTY。窄窗口临时只显示活动窗格，原布局保持不变。

文本编辑器使用原生 NSTextView，语法扫描在后台执行，颜色存入 NSLayoutManager 临时属性，不改变文件文本和撤销记录。文件树按展开操作读取目录，多文件草稿保留独立撤销记录。图片、PDF 和文档预览只接受经 ProjectFileStore 边界检查与大小限制后的数据；HTML、SVG 等仍按源码显示，不执行网页。

Git 面板通过有界的本地广度优先扫描发现独立仓库，保留根目录位于父仓库内部时的项目子目录范围。选择按项目路径记忆，提交草稿与文件选择按仓库隔离；状态和差异回调绑定仓库及加载代次。操作前复核工作目录、Git metadata 身份和项目边界，失效时清空旧状态；显式刷新后可重新选择。仓库扫描不执行远程 Git，暂存、提交完成后只重读当前仓库。目录路径复核不等同于抵御恶意并发文件系统替换的完整沙盒。

## 验证范围

自动测试使用临时目录、真实 CCAM 和模拟 Claude 事件，不调用真实模型 API。已验证连续两次额度耗尽后的接续、普通追问保持会话、停止及跨项目隔离。模拟测试不能保证所有未来 CCAM / Claude Code 版本具有相同行为。

桌面验收包含深浅主题、菜单尺寸、正文/输入对齐和原生按钮回调。系统鼠标自动化和真实浏览器 OAuth 不包含在这些测试中。


## 项目网页与本机 MCP

`ProjectWebView` owns per-project WebKit tabs, a project-specific data store, explicit shared proxy configuration, and a local tab metadata file. Navigation is opt-in after restore. `ProjectWorkspace` mounts the same browser across split-layout changes. The browser pane requires macOS 14+; other app capabilities retain macOS 13 support.

`WebMCPBridge` creates a private 0700 temporary directory, 0600 descriptor/configuration and a Unix-domain listener. The stdio helper (`--web-mcp`) runs before NSApplication initialization, implements MCP initialization/tool discovery, and forwards authenticated requests into the app. The bridge serializes operations, bounds frames and timeouts, and never launches Claude. Element refs are generated in an isolated WebKit content world and invalidated at navigation and each snapshot.

`ChatRuntime.webMCPArguments` is injected by the project workspace; the runtime remains independent of AppKit. Each turn and account continuation resolves the same project's current bridge configuration after the CCAM `--` separator. MCP tools do not bypass the existing permission channel. Per-project browser control can be revoked from its toolbar.

Tests: `Tests/web_browser_tests.sh` exercises actual WebKit against local-only HTTP/proxy fixtures, plus the stdio helper. It needs a normal macOS graphical session that permits WebKit child processes; restricted shell sandboxes may require running the test executable as an application bundle. `Tests/WebMCPTests.swift` checks delayed socket-frame delivery independently of WebKit. Neither test sends a Claude request.

## 同项目多对话

窗格布局保存对话 ID 映射，恢复旧版布局时迁移原单对话窗格。面板的移动与焦点独立于对话选择，关闭只隐藏缓存视图。聊天持久化合并本实例变化与文件最新内容，防止并行会话覆盖消息、翻译与管理元数据；会话固定绑定不跟随文件的全局选中项。项目的运行数与退出提示聚合所有对话实例。
