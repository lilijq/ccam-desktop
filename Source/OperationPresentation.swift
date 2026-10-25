import Foundation
import CoreFoundation

struct OperationLink: Equatable {
    let url: URL
    var title: String { url.host.map { "打开 \($0)" } ?? "打开链接" }
}

struct OperationSnapshot {
    let text: String
    let links: [OperationLink]
    let question: String?
    let affirmative: String?
    let hasIssues: Bool
}

/// Keeps incomplete UTF-8 and terminal escape sequences together before presenting them.
/// Raw bytes are used only for interpretation and explicit completion-script export.
final class OperationPresentation {
    private var bytes = Data()
    private var hiddenInputs: [String] = []
    private var submittedLines: [String] = []
    private var truncated = false
    var byteCount: Int { bytes.count }
    var plainOutput: String { Self.stripANSI(String(decoding: bytes, as: UTF8.self)) }

    func append(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
        if bytes.count > 2_097_152 {
            let suffix = bytes.suffix(1_048_576)
            if let newline = suffix.firstIndex(of: 10) { bytes = Data(suffix.suffix(from: suffix.index(after: newline))) }
            else { bytes = Data(suffix) }
            truncated = true
        }
    }
    func hideSubmittedInput(_ input: String) {
        guard !input.isEmpty else { return }
        submittedLines.append(input)
        if input.count >= 4 { hiddenInputs.append(input) }
    }
    func snapshot() -> OperationSnapshot {
        var plain = plainOutput
        for value in hiddenInputs { plain = plain.replacingOccurrences(of: value, with: "[已提交的输入已隐藏]") }
        plain = plain.components(separatedBy: .newlines).map { line in
            submittedLines.contains(line.trimmingCharacters(in: .whitespaces)) ? "[回复已提交]" : line
        }.joined(separator: "\n")
        let links = Self.links(in: plain)
        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        var text: String
        var hasIssues = false
        if let data = trimmed.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            text = Self.describe(object)
            hasIssues = Self.containsIssue(object)
        } else { text = Self.clean(plain) }
        if truncated { text = "较早的结果已省略。\n\n" + text }
        let tail = plain.components(separatedBy: .newlines).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        let confirmation = Self.confirmation(in: tail)
        return OperationSnapshot(text: text, links: links, question: confirmation == nil ? nil : Self.clean(tail), affirmative: confirmation, hasIssues: hasIssues)
    }

    private static func containsIssue(_ value: Any) -> Bool {
        if let rows = value as? [Any] { return rows.contains { containsIssue($0) } }
        guard let row = value as? [String: Any] else { return false }
        if row["status"] as? String == "error" { return true }
        if let error = row["error"] as? String, !error.isEmpty { return true }
        return row.values.contains { containsIssue($0) }
    }

    static func clean(_ text: String) -> String {
        let plain = redactSecrets(stripANSI(text))
        let result = plain.components(separatedBy: .newlines).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return "" }
            if line.range(of: "^[\\s│┃┆┊─━═┌┐└┘├┤┬┴┼╭╮╰╯+|=-]+$", options: .regularExpression) != nil { return nil }
            line = replacing("https?://[^\\s<>\\\"']+", in: line, with: "[链接]")
            line = replacing("(?i)`[^`]*\\bccam\\b[^`]*`", in: line, with: "相应面板操作")
            if line.range(of: "(?i)^ccam\\s+v?[0-9]", options: .regularExpression) != nil {
                line = replacing("(?i)^ccam\\s+", in: line, with: "版本：")
            } else if line.range(of: "(?i)^(?:[$>❯]\\s*)?[\\\"']?ccam[\\\"']?(?:\\s|$)", options: .regularExpression) != nil {
                return nil
            } else {
                line = replacing("(?i)\\bccam\\s+.*", in: line, with: "相应面板操作")
                line = replacing("(?i)\\bccam:", in: line, with: "操作提示：")
            }
            line = replacing("(?<![A-Za-z0-9])--?[A-Za-z][A-Za-z0-9_-]*(?:=[^\\s,;]+)?", in: line, with: "相关选项")
            line = line.replacingOccurrences(of: "│", with: "  ").replacingOccurrences(of: "┃", with: "  ")
            return line
        }.joined(separator: "\n")
        return replacing("\\n{3,}", in: result, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func stripANSI(_ text: String) -> String {
        enum State { case text, escape, csi, string, stringEscape, oneMore }
        var state = State.text, result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch state {
            case .text:
                if scalar.value == 27 { state = .escape }
                else if scalar.value == 155 { state = .csi }
                else if scalar.value == 8 { if !result.isEmpty { result.removeLast() } }
                else if scalar.value >= 32 || [9,10,13].contains(scalar.value) { result.append(scalar) }
            case .escape:
                if scalar == "[" { state = .csi }
                else if ["]", "P", "^", "_"].contains(String(scalar)) { state = .string }
                else if ["(", ")", "*", "+", "#", "%"].contains(String(scalar)) { state = .oneMore }
                else { state = .text }
            case .csi: if scalar.value >= 0x40 && scalar.value <= 0x7e { state = .text }
            case .string:
                if scalar.value == 7 { state = .text }
                else if scalar.value == 27 { state = .stringEscape }
            case .stringEscape: state = scalar == "\\" ? .text : .string
            case .oneMore: state = .text
            }
        }
        return String(result).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    private static func redactSecrets(_ text: String) -> String {
        var value = replacing("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+", in: text, with: "Bearer [已隐藏]")
        value = replacing("(?i)([\\\"']?(?:access[_-]?token|refresh[_-]?token|api[_-]?key|apikey|authorization|password|secret|client[_-]?secret|token|密钥|令牌)[\\\"']?\\s*[:=]\\s*)(?:\\\"[^\\\"]*\\\"?|'[^']*'?|[^\\s,;}\\]]+)", in: value, with: "$1[已隐藏]")
        value = replacing("\\bsk-[A-Za-z0-9_-]+", in: value, with: "[密钥已隐藏]")
        value = replacing("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", in: value, with: "[令牌已隐藏]")
        return value
    }
    private static func links(in text: String) -> [OperationLink] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\\\"']+") else { return [] }
        var result: [OperationLink] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;]}"))
            guard let parts = URLComponents(string: value), parts.user == nil, parts.password == nil,
                  let url = parts.url, ["https", "http"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil else { continue }
            // Authorization links are actionable; callback URLs and credentials are never surfaced.
            let secretNames = Set(["code", "token", "accesstoken", "refreshtoken", "apikey", "key", "password", "authorization", "clientsecret"])
            func isSecret(_ name: String) -> Bool { secretNames.contains(name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")) }
            if parts.queryItems?.contains(where: { isSecret($0.name) }) == true { continue }
            if let fragment = parts.fragment, fragment.split(separator: "&").contains(where: { isSecret(String($0.split(separator: "=", maxSplits: 1).first ?? "")) }) { continue }
            let item = OperationLink(url: url)
            if !result.contains(item) { result.append(item) }
            if result.count == 4 { break }
        }
        return result
    }
    private static func confirmation(in line: String) -> String? {
        let suffix = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.range(of: "(?i)(?:\\(yes/no\\)|\\[yes/no\\])\\s*[:?：？]?\\s*$", options: .regularExpression) != nil { return "yes" }
        if suffix.range(of: "(?i)(?:\\[y/n\\]|\\(y/n\\))\\s*[:?：？]?\\s*$", options: .regularExpression) != nil { return "y" }
        return nil
    }
    private static let names: [String: String] = [
        "name":"名称", "email":"邮箱", "status":"状态", "default":"默认", "plan":"套餐", "slot":"序号", "groups":"共享组", "group":"共享组", "dir":"目录", "directory":"目录", "path":"路径", "shortcut":"快捷方式", "source":"来源", "at":"更新时间", "error":"说明", "limits":"额度", "five_hour":"5 小时", "weekly":"每周", "scoped":"模型额度", "window":"额度窗口", "percent":"已使用（%）", "known":"数据可用", "resets_at":"重置时间", "members":"成员", "items":"共享内容", "type":"类型", "url":"服务地址", "transport":"连接方式", "server":"服务", "servers":"服务列表", "enabled":"已启用", "version":"版本"
    ]
    private static func describe(_ value: Any, indent: String = "") -> String {
        if let dict = value as? [String: Any] {
            if dict.isEmpty { return indent + "无记录" }
            return dict.keys.sorted().map { key in
                let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                let heading = names[key] ?? clean(key)
                if ["accesstoken","refreshtoken","apikey","authorization","password","secret","clientsecret","token"].contains(normalized) { return indent + heading + "：[已隐藏]" }
                if ["command","cmd","args","argv","arguments","executable"].contains(normalized) { return indent + "启动配置：已保存" }
                let child = dict[key]!
                if child is [String: Any] || child is [Any] { return indent + heading + "：\n" + describe(child, indent: indent + "  ") }
                return indent + heading + "：" + describe(child)
            }.joined(separator: "\n")
        }
        if let array = value as? [Any] {
            if array.isEmpty { return indent + "无记录" }
            return array.enumerated().map { index, child in
                if child is [String: Any] || child is [Any] { return indent + "记录 \(index + 1)\n" + describe(child, indent: indent + "  ") }
                return indent + "• " + describe(child)
            }.joined(separator: "\n\n")
        }
        if value is NSNull { return "暂无" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "是" : "否" }
            return number.stringValue
        }
        let text = String(describing: value)
        let statuses = ["logged_out":"尚未登录", "expired":"登录已过期", "ok":"正常", "active":"可用", "api":"API 账号", "cache":"缓存", "unauthorized":"需要登录", "error":"读取异常"]
        return statuses[text] ?? clean(text)
    }
}
