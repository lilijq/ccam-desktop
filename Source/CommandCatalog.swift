import Foundation

struct CommandEntry {
    let path: [String]
    let category: String
    let spec: ActionSpec
    var commandText: String { (["ccam"] + path).joined(separator: " ") }
}

enum CommandCatalog {
    static let categories = ["账号与登录", "启动与会话", "额度查询", "共享组", "MCP 与扩展", "项目与迁移", "维护与补全", "内部集成"]
    static var all: [CommandEntry] {
        var entries: [CommandEntry] = []
        func add(_ category: String, _ path: [String], _ title: String, _ detail: String, fields: [FieldSpec] = [], dry: Bool = false, launch: Bool = false, options: [(String, [String])] = []) {
            var spec = Catalog.positional(title, detail, path, fields, dry: dry, launch: launch)
            spec.options = options
            entries.append(CommandEntry(path: path, category: category, spec: spec))
        }
        func custom(_ category: String, _ path: [String], _ spec: ActionSpec) { entries.append(CommandEntry(path: path, category: category, spec: spec)) }
        let account = Catalog.account
        let optionalAccount = Catalog.field("账号（可选）", "account", "留空使用项目绑定或默认账号", required: false)
        let optionalFolder = Catalog.field("文件夹（可选）", "folder", "留空使用 CCAM 默认位置", required: false)
        let c = categories
        add(c[0], ["list"], "账号列表", "列出所有账号、默认标记与快捷命令。", options: [("JSON 输出", ["--json"])])
        add(c[0], ["add"], "新增账号", "在内置终端中创建账号，浏览器完成授权。", fields: [account], options: [("暂不登录", ["--no-login"]), ("不加入共享组", ["--no-group"])])
        custom(c[0], ["add", "--api"], ActionSpec(title: "新增 API 账号", detail: "密钥由环境变量或密码管理器提供。", command: ["add"], fields: [account, Catalog.field("密钥来源", "key", "env:MY_API_KEY 或 command:…"), Catalog.field("服务地址（可选）", "url", "https://…", required: false)], build: { v in
            guard v["key"]!.hasPrefix("env:") || v["key"]!.hasPrefix("command:") else { throw AppError.message("请填写 env: 或 command: 密钥来源。") }
            var a = ["add", v["account"]!, "--api", "--key-from", v["key"]!]; if let u = v["url"], !u.isEmpty { a += ["--base-url", u] }; return a
        }))
        add(c[0], ["login"], "登录账号", "重新登录指定账号，保留 MCP 授权。", fields: [account])
        add(c[0], ["login", "--expired"], "登录过期账号", "只为已过期账号启动登录流程。")
        add(c[0], ["logout"], "退出登录", "撤销该账号登录及 MCP 授权；由 CCAM 询问确认。", fields: [account])
        add(c[0], ["use"], "设置默认账号", "更改后续启动的默认账号，已有会话保持运行。", fields: [account])
        add(c[0], ["rename"], "重命名账号", "更改账号名称，由 CCAM 保留登录关联。", fields: [account, Catalog.field("新名称", "new", "personal")])
        add(c[0], ["remove"], "移除账号", "由 CCAM 确认并处理登录和账号目录。", fields: [account])
        add(c[0], ["share"], "查看共享来源", "查看账号从哪些共享组获得哪些内容。", fields: [account])
        add(c[0], ["shortcut"], "查看快捷命令", "显示该账号的快捷命令。", fields: [account])
        add(c[0], ["shortcut"], "设置快捷命令", "创建或重命名此账号的快捷启动命令。", fields: [account, Catalog.field("命令名称", "shortcut", "ccwork")])
        add(c[0], ["shortcut", "--remove"], "删除快捷命令", "仅删除快捷链接，保留账号。", fields: [account])

        add(c[1], [], "原版 CCAM 面板", "在内置终端打开 CCAM 全屏交互面板；使用方向键和 Enter。", launch: true)
        add(c[1], ["run"], "启动 Claude Code", "在内置终端使用指定账号启动 Claude Code。", fields: [optionalAccount], dry: true, launch: true)
        custom(c[1], ["run", "--resume"], ActionSpec(title: "恢复历史会话", detail: "使用会话选择器恢复当前项目的对话。", command: ["run"], fields: [account], launchesClaude: true, build: { ["run",$0["account"]!,"--resume"] }))
        custom(c[1], ["run", "--continue"], ActionSpec(title: "继续最近会话", detail: "以指定账号继续当前项目最近的对话。", command: ["run"], fields: [account], launchesClaude: true, build: { ["run",$0["account"]!,"--continue"] }))
        add(c[1], ["agents"], "查看运行会话", "列出各账号的后台与打开的会话。", options: [("包括已完成会话", ["--all"]), ("JSON 输出", ["--json"])])
        add(c[1], ["attach"], "连接后台会话", "按会话 ID 或名称打开其所属账号的后台会话。", fields: [Catalog.field("会话 ID / 名称", "id", "49ec0028")], launch: true)
        add(c[1], ["next"], "切换下一个账号", "打开下一个账号，可继续当前项目对话。", dry: true, launch: true, options: [("继续最近对话", ["--continue"]), ("按额度自动选择", ["--auto"])])
        add(c[1], ["next", "--auto", "--continue"], "按额度接续对话", "自动选择仍有额度的账号，继续同一项目对话。", dry: true, launch: true)
        custom(c[1], ["run", "--fallback"], ActionSpec(title: "自动回退批处理", detail: "执行单次提示词；额度不足时由 CCAM 选择另一个可用账号。", command: ["run"], fields: [account, Catalog.field("提示词", "prompt", "说明要执行的任务")], dryRun: true, launchesClaude: true, build: { ["run", "--fallback", $0["account"]!, "-p", $0["prompt"]!] }))
        custom(c[1], ["run", "rc"], ActionSpec(title: "Remote Control", detail: "在内置终端以指定账号启动 Claude Remote Control。", command: ["run"], fields: [account], launchesClaude: true, build: { ["run", $0["account"]!, "rc"] }))

        add(c[2], ["usage"], "查询账号额度", "查看 5 小时、每周和模型专属额度。", options: [("显示来源详情", ["--verbose"]), ("JSON 输出", ["--json"]), ("绕过缓存", ["--no-cache"])])
        add(c[2], ["usage", "--watch"], "实时监视额度", "持续刷新额度，按 Ctrl-C 停止；切换页面时继续运行。")
        add(c[2], ["usage", "--refresh"], "刷新过期令牌", "显式尝试刷新非运行账号的令牌。")
        add(c[2], ["usage", "--source", "cache"], "查看缓存额度", "读取 CCAM 已保存的额度信息。")
        add(c[2], ["usage", "--source", "claude"], "通过 Claude 查询额度", "由 Claude Code 查询用量，耗时可能较长。")
        add(c[2], ["pick"], "推荐可用账号", "只返回 CCAM 推荐的账号。", options: [("JSON 输出", ["--json"])])
        add(c[2], ["pick", "--wait"], "等待可用额度", "没有账号可用时等待额度恢复，按 Ctrl-C 取消。")

        add(c[3], ["group"], "共享组总览", "显示全部共享组。")
        add(c[3], ["group", "list"], "共享组列表", "列出每组的共享项和成员。")
        for spec in Catalog.groups { custom(c[3], spec.command, spec) }

        add(c[4], ["mcp", "list"], "MCP 服务列表", "查看共享及账号独立的 MCP 服务。")
        for spec in Catalog.mcp { custom(c[4], spec.command, spec) }
        custom(c[4], ["mcp", "add"], ActionSpec(title: "添加本地 stdio MCP", detail: "启动本地命令作为 MCP 服务，参数使用 JSON 数组。", command: ["mcp", "add"], fields: [Catalog.field("服务名称", "name", "filesystem"), Catalog.field("可执行命令", "executable", "npx"), Catalog.field("命令参数数组", "args", "[\"-y\",\"@modelcontextprotocol/server-filesystem\",\"/path\"]"), Catalog.field("共享组（可选）", "group", "default", required: false)], build: { v in
            var a = ["mcp", "add", v["name"]!]; if let g=v["group"], !g.isEmpty { a += ["--group",g] }; return a + ["--",v["executable"]!] + (try Shell.arguments(v["args"]!))
        }))
        add(c[4], ["ext"], "扩展来源与检查", "显示扩展来源和配置冲突；账号留空时检查全部账号。", fields: [optionalAccount], options: [("JSON 输出", ["--json"])])
        add(c[5], ["folder"], "查看项目绑定", "查看目录与账号的映射关系。")
        add(c[5], ["folder"], "绑定项目账号", "此目录及其子目录的默认启动使用指定账号。", fields: [account, Catalog.folder])
        add(c[5], ["folder", "--remove"], "解除项目绑定", "恢复使用全局默认账号。", fields: [Catalog.folder])
        add(c[5], ["import"], "导入已有账号", "原位登记已有配置目录；留空时由 CCAM 搜索。", fields: [optionalFolder])
        add(c[5], ["migrate"], "迁移现有设置", "复制所选设置到共享组；先预览再执行。", fields: [optionalFolder], dry: true, options: [("设置", ["--settings"]), ("全局记忆", ["--memory"]), ("扩展", ["--extensions"]), ("MCP", ["--mcp"]), ("对话历史", ["--history"])])

        for spec in Catalog.maintenance where !["import","migrate","login","usage"].contains(spec.command.first ?? "") { custom(c[6], spec.command, spec) }
        add(c[6], ["version"], "查看 CCAM 版本", "显示当前可执行文件的版本。")
        add(c[6], ["help"], "全部命令帮助", "显示本机 CCAM 支持的全部命令。")
        add(c[6], ["help"], "指定命令帮助", "例如填写 usage、group 或 mcp。", fields: [Catalog.field("命令名称", "command", "usage")])
        for shell in ["bash","zsh","powershell"] { add(c[6], ["completion",shell], "生成 \(shell) 补全", "在终端输出补全脚本，可选中复制；不自动修改 shell 配置。") }
        custom(c[6], ["update", "--version"], ActionSpec(title: "安装指定 CCAM 版本", detail: "安装指定发布版本；支持先预览下载计划。", command: ["update"], fields: [Catalog.field("版本号", "version", "v0.11.0")], dryRun: true, build: { ["update","--version",$0["version"]!] }))

        for (path,title) in [(["hook","stop-failure"],"额度失败 Hook"),(["hook","switch"],"切换账号 Hook"),(["statusline"],"状态栏输入调试")] {
            var spec = ActionSpec(title: title, detail: "供插件集成调试。粘贴符合 Claude Hook / 状态栏格式的 JSON；运行后发送至标准输入。缺少真实会话环境时 CCAM 会拒绝或忽略。", command: path, fields: [Catalog.field("标准输入 JSON", "stdin", "{\"session_id\":\"…\"}")])
            spec.stdinKey = "stdin"; custom(c[7],path,spec)
        }
        return entries
    }
    static var requiredCommandPaths: Set<String> {
        Set(["add","agents","attach","completion bash","completion zsh","completion powershell","doctor","ext","folder","group list","group add","group set","group join","group leave","group show","group rename","group remove","help","hook stop-failure","hook switch","import","list","login","logout","mcp list","mcp add","mcp add-json","mcp import","mcp remove","migrate","next","pick","remove","rename","run","share","shims install","shortcut","statusline","statusline install","update","usage","use","version"])
    }
}
