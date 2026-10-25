import Foundation

/// A narrow display filter for app-managed CCAM launches, never a shell parser.
/// It changes only visible `ccam <known operation/account>` hints. ANSI sequences
/// and non-matching UTF-8 bytes pass through unchanged, including trust prompts.
/// This class must not be used to decide process state or account switching.
final class TerminalCommandFilter {
    static let replacement = "请使用面板中的对应功能"
    private enum TextState { case normal, prefix, afterName, gap, command, suppressing }
    private enum EscapeState { case none, escape, csi, string, stringEscape, oneMore }
    private var textState = TextState.normal
    private var escapeState = EscapeState.none
    private var candidate = [UInt8]()
    private var candidateControls = [UInt8]()
    private var command = [UInt8]()
    private var prefixCount = 0
    private var gapCount = 0
    private var suppressedCount = 0
    private var escape = [UInt8]()
    private var confirmation = [UInt8]()
    private var lastWasWord = false
    private let accountNames: Set<String>
    private let maximumSuppressedBytes: Int
    private static let name = Array("ccam".utf8)
    private static let confirmationMarkers = ["[y/n]", "(y/n)", "[yes/no]", "(yes/no)"].map { Array($0.utf8) }
    private static let operations: Set<String> = [
        "add", "agents", "attach", "completion", "doctor", "ext", "folder", "group",
        "help", "hook", "import", "list", "login", "logout", "mcp", "migrate", "next",
        "pick", "remove", "rename", "run", "share", "shims", "shortcut", "statusline",
        "update", "usage", "use", "version", "--help", "--version", "--fallback", "--dry-run", "-h", "-v"
    ]

    init(accountNames: [String] = [], maximumSuppressedBytes: Int = 8192) {
        self.accountNames = Set(accountNames.map { $0.lowercased() })
        self.maximumSuppressedBytes = max(64, maximumSuppressedBytes)
    }

    func append(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(bytes.count)
        for byte in bytes {
            if escapeState != .none { acceptEscape(byte, output: &result) }
            else if byte == 27 { escape = [byte]; escapeState = .escape }
            else { acceptText(byte, output: &result) }
        }
        return result
    }

    /// Call when the child exits so a final ordinary word is not left buffered.
    func finish() -> [UInt8] {
        var result = [UInt8]()
        resolveCandidate(output: &result)
        result += escape
        reset()
        return result
    }

    /// Start a fresh stream when a PTY is reused for the next account.
    func reset() {
        textState = .normal; escapeState = .none
        candidate.removeAll(keepingCapacity: true); candidateControls.removeAll(keepingCapacity: true)
        command.removeAll(keepingCapacity: true); escape.removeAll(keepingCapacity: true)
        confirmation.removeAll(keepingCapacity: true)
        prefixCount = 0; gapCount = 0; suppressedCount = 0; lastWasWord = false
    }

    private static func lower(_ byte: UInt8) -> UInt8 { (65...90).contains(byte) ? byte + 32 : byte }
    private static func isWord(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
    }
    private var isCandidate: Bool { textState != .normal && textState != .suppressing }
    private var isKnownCommand: Bool {
        let token = String(decoding: command, as: UTF8.self).lowercased()
        return Self.operations.contains(token) || accountNames.contains(token)
            || (!command.isEmpty && command.allSatisfy { (48...57).contains($0) })
    }

    private func acceptText(_ byte: UInt8, output: inout [UInt8]) {
        switch textState {
        case .normal:
            if Self.lower(byte) == 99 && !lastWasWord {
                candidate = [byte]; candidateControls.removeAll(keepingCapacity: true)
                prefixCount = 1; textState = .prefix
            } else { output.append(byte) }
        case .prefix:
            if Self.lower(byte) == Self.name[prefixCount] {
                candidate.append(byte); prefixCount += 1
                if prefixCount == Self.name.count { textState = .afterName }
            } else {
                flushCandidate(output: &output); acceptText(byte, output: &output); return
            }
        case .afterName:
            if byte == 32 || byte == 9 {
                candidate.append(byte); gapCount = 1; textState = .gap
            } else {
                flushCandidate(output: &output); acceptText(byte, output: &output); return
            }
        case .gap:
            if (byte == 32 || byte == 9) && gapCount < 32 {
                candidate.append(byte); gapCount += 1
            } else if Self.isWord(byte) {
                candidate.append(byte); command = [byte]; textState = .command
            } else {
                flushCandidate(output: &output); acceptText(byte, output: &output); return
            }
        case .command:
            if Self.isWord(byte) && command.count < 64 {
                candidate.append(byte); command.append(byte)
            } else {
                resolveCandidate(output: &output); acceptText(byte, output: &output); return
            }
        case .suppressing:
            if byte == 10 || byte == 13 || byte == 8 {
                textState = .normal; suppressedCount = 0; confirmation.removeAll(keepingCapacity: true); output.append(byte)
            } else if suppressedCount >= maximumSuppressedBytes && !(0x80...0xbf).contains(byte) {
                // Leave suppression at a UTF-8 boundary, never midway through a glyph.
                textState = .normal; suppressedCount = 0; confirmation.removeAll(keepingCapacity: true); acceptText(byte, output: &output); return
            } else {
                suppressedCount += 1
                preserveConfirmation(byte, output: &output)
            }
        }
        lastWasWord = Self.isWord(byte)
    }

    private func preserveConfirmation(_ byte: UInt8, output: inout [UInt8]) {
        if confirmation.isEmpty {
            if byte == 91 || byte == 40 { confirmation = [byte] }
            return
        }
        confirmation.append(byte)
        let lower = confirmation.map(Self.lower)
        if Self.confirmationMarkers.contains(lower) {
            // A prompt can share the command's logical line. Keep its explicit
            // consent choice visible rather than assuming a newline precedes it.
            output.append(32); output += confirmation
            confirmation.removeAll(keepingCapacity: true)
            textState = .normal; suppressedCount = 0
        } else if !Self.confirmationMarkers.contains(where: { $0.starts(with: lower) }) {
            confirmation = (byte == 91 || byte == 40) ? [byte] : []
        }
    }

    private func resolveCandidate(output: inout [UInt8]) {
        guard isCandidate else { return }
        if textState == .command && isKnownCommand {
            // Preserve every buffered SGR, including resets, even though the
            // visible command and its arguments are not rendered.
            output += candidateControls
            output += Array(Self.replacement.utf8)
            candidate.removeAll(keepingCapacity: true); candidateControls.removeAll(keepingCapacity: true)
            command.removeAll(keepingCapacity: true); textState = .suppressing; suppressedCount = 0
        } else { flushCandidate(output: &output) }
    }

    private func flushCandidate(output: inout [UInt8]) {
        output += candidate
        candidate.removeAll(keepingCapacity: true); candidateControls.removeAll(keepingCapacity: true)
        command.removeAll(keepingCapacity: true); textState = .normal
    }

    private func acceptEscape(_ byte: UInt8, output: inout [UInt8]) {
        escape.append(byte)
        var complete = false
        switch escapeState {
        case .none: break
        case .escape:
            switch byte {
            case 91: escapeState = .csi
            case 93, 80, 94, 95, 88: escapeState = .string
            case 40, 41, 42, 43, 35, 37: escapeState = .oneMore
            default: complete = true
            }
        case .csi: complete = (0x40...0x7e).contains(byte)
        case .string:
            if byte == 7 { complete = true }
            else if byte == 27 { escapeState = .stringEscape }
        case .stringEscape:
            if byte == 92 { complete = true }
            else if byte != 27 { escapeState = .string }
        case .oneMore: complete = true
        }
        if complete {
            let sequence = escape
            escape.removeAll(keepingCapacity: true); escapeState = .none
            let sgr = sequence.count >= 3 && sequence[0] == 27 && sequence[1] == 91 && sequence.last == 109
            if sgr && isCandidate {
                candidate += sequence; candidateControls += sequence
                if candidate.count >= 16384 { flushCandidate(output: &output) }
            } else {
                resolveCandidate(output: &output)
                if cursorBoundary(sequence) { textState = .normal; suppressedCount = 0; lastWasWord = false; confirmation.removeAll(keepingCapacity: true) }
                output += sequence
            }
        } else if escape.count >= 16384 {
            // OSC/DCS strings can contain arbitrary bytes. Stream long strings
            // opaquely, keeping their parser state, rather than interpreting them.
            resolveCandidate(output: &output)
            output += escape; escape.removeAll(keepingCapacity: true)
        }
    }

    private func cursorBoundary(_ sequence: [UInt8]) -> Bool {
        guard sequence.first == 27, let final = sequence.last else { return false }
        if sequence.count >= 3 && sequence[1] == 91 {
            // Cursor movement, insertion/deletion, scrolling and erase all mark a
            // new visual context. The next trust/permission prompt must stay visible.
            return Array("ABCDEFGHJKLMPSTXZ`adefghlrstu".utf8).contains(final)
        }
        return sequence.count == 2 && Array("78DEMc".utf8).contains(final)
    }
}
