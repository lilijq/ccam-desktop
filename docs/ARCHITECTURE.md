# 架构

CCAM Desktop 是本地 Swift/AppKit 客户端。它调用用户安装的 CCAM 和 Claude Code，使用原生视图处理聊天、文件、Git 和终端；没有网页服务器或额外的云端账户后台。

| 层 | 主要文件 | 职责 |
| --- | --- | --- |
| 界面 | `App.swift`、`WorkspaceSidebar.swift`、`Theme.swift` | 项目导航、左下管理菜单、外观 |
| 项目 | `ProjectStore.swift`、`ProjectWorkspace.swift` | 项目目录、归档和各项目视图 |
| 聊天 | `ChatStore.swift`、`ChatRuntime.swift`、`ProjectChatView.swift` | 本地历史、草稿、流式输出和精确会话恢复 |
| 账号池 | `GlobalPool.swift`、`PoolCoordinator.swift` | 根据账号额度选用账号，在明确额度事件后接续 |
| 浏览器资料 | `BrowserLockStore.swift`、`BrowserRouting.swift`、`BrowserSettingsGuard.swift` | Chrome 资料选择、登录路由与配置冲突检查 |
| 文件与 Git | `ProjectFiles.swift`、`ProjectGit.swift` | 目录浏览、文本编辑、差异与暂存/提交 |
| 终端 | `PTYSession.swift`、`PTYBridge.c`、`TerminalWorkspace.swift` | 进程生命周期、PTY 和 SwiftTerm 渲染 |

## 会话与账号

项目保存工作目录、草稿和会话上下文。账号额度在全局账号池中管理，项目不绑定固定额度。一次运行记录原生会话身份；只有明确的额度耗尽事件触发换号。下一账号恢复精确会话，保留目录与成果，不重复执行最初提示词。普通错误和停止操作不会触发换号。

普通追问继续使用原账号及原会话。没有可接续的账号时，已开始的任务可等待额度恢复或取消；首次启动就没有可用账号会报错。需要交互式权限确认的会话可移交内置终端，移交后的图形对话只读。

## 数据位置

应用数据默认位于 `~/Library/Application Support/CCAM Desktop/`，包括项目列表、Chrome 资料绑定和按项目保存的聊天记录。凭据、额度缓存与原生历史由 CCAM / Claude Code 管理。

`CCAM_DESKTOP_DATA_DIR`、`CCAM_HOME` 和 `CCAM_EXECUTABLE` 可用于隔离测试。不要将真实凭据或本机数据目录提交到仓库。

## 验证范围

自动测试使用临时目录、真实 CCAM 和模拟 Claude 事件，不调用真实模型 API。已验证连续两次额度耗尽后的接续、普通追问保持会话、停止及跨项目隔离。模拟测试不能保证所有未来 CCAM / Claude Code 版本具有相同行为。

桌面验收包含深浅主题、菜单尺寸、正文/输入对齐和原生按钮回调。系统鼠标自动化和真实浏览器 OAuth 不包含在这些测试中。
