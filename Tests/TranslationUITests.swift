import AppKit

private final class TranslationFixtureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class ControlledTranslator: ChatTranslating {
    final class Job {
        let text: String
        let source: TranslationLanguage
        let target: TranslationLanguage
        let completion: (Result<String, Error>) -> Void
        var cancelled = false
        init(_ text: String, _ source: TranslationLanguage, _ target: TranslationLanguage, _ completion: @escaping (Result<String, Error>) -> Void) {
            self.text = text; self.source = source; self.target = target; self.completion = completion
        }
    }
    var jobs: [Job] = []
    func translate(_ text: String, from: TranslationLanguage, to: TranslationLanguage, completion: @escaping (Result<String, Error>) -> Void) -> TranslationRequest {
        let job = Job(text, from, to, completion); jobs.append(job)
        return TranslationRequest(cancel: { job.cancelled = true })
    }
}

enum TranslationUITests {
    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccam-translation-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(id: UUID(), name: "本机翻译", path: root.path, createdAt: Date(), lastOpenedAt: Date(), archived: false)
        var settings = ChatOptions(model: "haiku", permissionMode: .default, effort: "low")
        settings.translateToEnglish = true; settings.autoTranslateReplies = false
        var first = ChatConversation(id: UUID().uuidString, title: "翻译与上下文", projectID: project.id.uuidString, directory: root.path, options: settings)
        var user = ChatMessage(role: "user", text: "Explain the file tree.\n\nPlease respond in English.")
        user.originalText = "解释一下文件树。"
        let answer = ChatMessage(role: "assistant", text: "The file tree shows your project folders. Open `src/main.rs` to inspect the entry point.")
        first.messages = [user, answer]
        var second = ChatConversation(id: UUID().uuidString, title: "另一段对话", projectID: project.id.uuidString, directory: root.path, options: settings)
        second.messages = [ChatMessage(role: "user", text: "Explain the command."), ChatMessage(role: "assistant", text: "Run `git status` to see the working tree changes.")]
        try ChatStore(project: project).save([first, second], selectedID: first.id)
        let translator = ControlledTranslator()
        let view = ProjectChatView(project: project, translator: translator)
        view.beforeStart = { _ in throw AppError.message("Translation UI fixtures never start Claude") }
        let window = TranslationFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 968, height: 720), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView = view
        func all() -> [NSView] { ChatUITests.all(view) }
        func button(_ label: String) -> NSButton? { all().compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label } }
        let input = all().compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "对话输入" }!
        func draft(_ text: String) { input.string = text; view.textDidChange(Notification(name: NSText.didChangeNotification)) }
        func textVisible(_ text: String) -> Bool { all().compactMap { $0 as? NSTextField }.contains { $0.stringValue == text } }
        func preference(_ tag: Int) {
            let item = view.translationSettingsMenu().items.first { $0.tag == tag }!
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        func settle() {
            for _ in 0..<4 { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        check(translator.jobs.isEmpty, "opening saved history never triggers automatic translation work")
        check(textVisible(user.originalText!) && !textVisible(user.text), "translated user prompt presents the original Chinese first")
        button("查看发送的英文")!.performClick(nil)
        check(textVisible(user.text), "user can inspect the exact outbound English and language instruction")
        button("收起发送的英文")!.performClick(nil)
        check(!textVisible(user.text), "outbound English can be collapsed without changing the transcript")

        draft("  请解释这个项目。  ")
        button("发送消息")!.performClick(nil)
        check(translator.jobs.count == 1 && translator.jobs[0].source == .chinese && translator.jobs[0].target == .english, "Chinese input translates locally before sending")
        check(view.hasRunning && button("取消翻译")?.isHidden == false && button("发送消息")?.isEnabled == false, "outgoing translation is cancellable and blocks duplicate sends")
        check(input.isEditable && button("翻译设置")?.isEnabled == false && view.translationSettingsMenu().items.filter { $0.action == Selector(("translationPreferenceChanged:")) }.allSatisfy { !$0.isEnabled },
              "translation loading keeps the draft editable while exposing disabled preference controls")
        let pendingStored = try ChatStore(project: project)
        check(pendingStored.conversations.first { $0.id == first.id }!.messages.count == 2, "pending translation never commits a user turn")
        draft("请保留新的草稿。")
        check(translator.jobs[0].cancelled && !view.hasRunning, "editing during translation cancels the stale request")
        translator.jobs[0].completion(.success("This obsolete translation must never be sent."))
        check(input.string == "请保留新的草稿。" && !view.hasRunning, "a late cancelled callback cannot clear or send edited content")
        button("发送消息")!.performClick(nil)
        button("取消翻译")!.performClick(nil)
        check(translator.jobs[1].cancelled && input.string == "请保留新的草稿。", "stop during translation keeps the original draft")
        translator.jobs[1].completion(.success("Still stale."))
        button("发送消息")!.performClick(nil)
        view.selectConversation(id: second.id)
        translator.jobs[2].completion(.success("Wrong conversation."))
        check(translator.jobs[2].cancelled && view.selectedConversationID == second.id && input.string.isEmpty, "switching conversations rejects the previous draft's translation")
        view.selectConversation(id: first.id)
        check(input.string == "请保留新的草稿。", "cancelled translation preserves each conversation's independent draft")
        button("发送消息")!.performClick(nil)
        translator.jobs[3].completion(.failure(AppError.message("本机翻译暂时不可用")))
        check(!view.hasRunning && input.string == "请保留新的草稿。" && textVisible("翻译未完成：本机翻译暂时不可用"), "translation failure preserves the draft and explains why nothing was sent")
        check(button("重试翻译")?.isHidden == false && button("重试翻译")?.isEnabled == true,
              "a failed local translation exposes an explicit retry beside the composer")
        let outgoingRetryCount = translator.jobs.count
        button("重试翻译")!.performClick(nil)
        check(translator.jobs.count == outgoingRetryCount + 1 && translator.jobs.last!.text == "请保留新的草稿。" && input.string == "请保留新的草稿。",
              "composer retry translates the original draft once without clearing it")
        check(button("重试翻译")?.isHidden == true && button("重试翻译")?.isEnabled == false && view.hasRunning,
              "the retry control is hidden and disabled while a retry is pending")
        button("重试翻译")!.performClick(nil)
        check(translator.jobs.count == outgoingRetryCount + 1, "repeated retry clicks cannot start duplicate translations")
        translator.jobs.last!.completion(.success("  \n"))
        check(button("重试翻译")?.isHidden == false && input.string == "请保留新的草稿。" && !view.hasRunning,
              "an empty translation result rolls back to the same retryable draft")
        view.selectConversation(id: second.id)
        check(button("重试翻译")?.isHidden == true, "a failed draft's retry never leaks into another conversation")
        view.selectConversation(id: first.id)
        check(input.string == "请保留新的草稿。" && button("重试翻译")?.isHidden == true,
              "returning to a draft retains its text without restoring stale retry state")
        let cancelledStored = try ChatStore(project: project)
        check(cancelledStored.conversations.first { $0.id == first.id }!.messages.count == 2, "all cancelled or failed translations leave the stored transcript unchanged")
        draft("")

        button("翻译回复为中文")!.performClick(nil)
        let replyJob = translator.jobs.last!
        check(replyJob.source == .english && replyJob.target == .chinese && replyJob.text == answer.text, "reply icon translates only the selected English reply")
        check(button("正在翻译回复")?.isEnabled == false, "reply translation cannot be duplicated while pending")
        replyJob.completion(.success("文件树显示项目中的文件夹。打开 `src/main.rs` 查看入口。"))
        let translated = try ChatStore(project: project).conversations.first { $0.id == first.id }!.messages.first { $0.id == answer.id }!
        check(translated.text == answer.text && translated.translatedText?.contains("文件树") == true, "reply translation is cached separately without replacing the original")
        check(textVisible(answer.text) && textVisible(translated.translatedText!), "manual mode expands Chinese beneath the English original")
        let calls = translator.jobs.count
        button("收起中文翻译")!.performClick(nil); button("翻译回复为中文")!.performClick(nil)
        check(translator.jobs.count == calls && textVisible(translated.translatedText!), "reopening a cached translation performs no new work")
        button("收起中文翻译")!.performClick(nil)
        preference(1)
        check(textVisible(translated.translatedText!) && !textVisible(answer.text) && button("查看英文原文") != nil, "automatic mode presents cached Chinese as the primary reply")
        button("查看英文原文")!.performClick(nil)
        check(textVisible(answer.text) && textVisible(translated.translatedText!), "automatic Chinese mode retains access to original English")
        button("收起英文原文")!.performClick(nil)
        preference(0)
        let options = try ChatStore(project: project).conversations.first { $0.id == first.id }!.options!
        check(options.translateToEnglish == false && options.autoTranslateReplies == true && options.model == "haiku" && options.effort == "low", "translation preferences are independent and preserve model options")
        preference(0)

        for width in [CGFloat(968), CGFloat(640), CGFloat(358)] {
            window.setContentSize(NSSize(width: width, height: 720)); settle()
            for item in all().filter({ ["翻译设置", "发送消息", "添加图片或文件", "选择模型", "选择思考强度", "选择权限模式"].contains($0.accessibilityLabel() ?? "") }) {
                let rect = item.convert(item.bounds, to: view)
                check(rect.minX >= -0.5 && rect.maxX <= view.bounds.width + 0.5 && rect.minY >= 0, "translation controls fit width \(width)")
            }
            let point = input.convert(NSPoint(x: 20, y: 20), to: view)
            check(input.bounds.width >= 180 && view.hitTest(point) === input, "translation badge leaves the input clickable at width \(width)")
            if width == 968 { try ChatUITests.snapshot(view, name: "translation-auto-chinese-desktop") }
            if width == 358 { try ChatUITests.snapshot(view, name: "translation-auto-chinese-compact") }
        }
        view.selectConversation(id: second.id)
        button("翻译回复为中文")!.performClick(nil)
        let staleReply = translator.jobs.last!
        view.selectConversation(id: first.id)
        staleReply.completion(.success("不应写到其他对话。"))
        check(staleReply.cancelled && !textVisible("不应写到其他对话。"), "late reply translations cannot alter another conversation")
        let abandonedStored = try ChatStore(project: project)
        check(abandonedStored.conversations.first { $0.id == second.id }!.messages.last!.translatedText == nil, "abandoned reply translation does not modify hidden history")

        view.selectConversation(id: second.id)
        check(view.translationSettingsMenu().items.first { $0.tag == 1 }?.state == .off && button("翻译回复为中文") != nil,
              "another conversation retains manual reply translation independently")
        preference(0)
        let independent = try ChatStore(project: project).conversations
        check(independent.first { $0.id == first.id }?.options?.translateToEnglish == true && independent.first { $0.id == first.id }?.options?.autoTranslateReplies == true
              && independent.first { $0.id == second.id }?.options?.translateToEnglish == false && independent.first { $0.id == second.id }?.options?.autoTranslateReplies == false,
              "disabling outgoing translation never changes another conversation or its reply preference")
        button("翻译回复为中文")!.performClick(nil)
        let failedReply = translator.jobs.last!
        failedReply.completion(.failure(AppError.message("本机模型尚未准备好，请重试。")))
        let afterFailure = try ChatStore(project: project).conversations.first { $0.id == second.id }!.messages.last!
        check(textVisible(second.messages.last!.text) && textVisible("本机模型尚未准备好，请重试。") && afterFailure.translatedText == nil,
              "reply translation failure preserves the exact English and provides an inline error without caching it")
        let failedJobCount = translator.jobs.count
        settle()
        check(button("翻译回复为中文")?.isEnabled == true && translator.jobs.count == failedJobCount,
              "failed reply remains retryable without starting an automatic retry loop")
        button("翻译回复为中文")!.performClick(nil)
        let retriedReply = translator.jobs.last!
        check(translator.jobs.count == failedJobCount + 1 && retriedReply.text == second.messages.last!.text,
              "explicit retry translates the unchanged original English once")
        retriedReply.completion(.success("运行 `git status` 查看工作区改动。"))
        check(textVisible("运行 `git status` 查看工作区改动。") && !textVisible("本机模型尚未准备好，请重试。"),
              "a successful retry replaces the error with Chinese while preserving the command")
        button("收起中文翻译")!.performClick(nil)
        let retryCalls = translator.jobs.count
        preference(1)
        button("查看英文原文")!.performClick(nil)
        check(textVisible(second.messages.last!.text) && textVisible("运行 `git status` 查看工作区改动。") && translator.jobs.count == retryCalls,
              "switching a retried cached reply to automatic Chinese still reveals exact English without retranslating")
        button("收起英文原文")!.performClick(nil)
        preference(0)

        let brief = root.appendingPathComponent("brief.md"), sample = root.appendingPathComponent("sample.rs")
        try "# Offline attachment fixture".write(to: brief, atomically: true, encoding: .utf8)
        try "fn main() {}".write(to: sample, atomically: true, encoding: .utf8)
        try view.addAttachments([brief, sample])
        let longDraft = String(repeating: "请结合附件解释这个项目的接口与依赖。\n", count: 220)
        draft(longDraft)
        button("发送消息")!.performClick(nil)
        let attachmentJob = translator.jobs.last!
        check(attachmentJob.text == longDraft.trimmingCharacters(in: .whitespacesAndNewlines) && input.string == longDraft,
              "long multi-attachment drafts are translated without truncation or premature clearing")
        var rejectedAttachment = false
        do { try view.addAttachments([brief]) } catch { rejectedAttachment = true }
        check(rejectedAttachment && button("添加图片或文件")?.isEnabled == false,
              "adding attachments is blocked while the outgoing translation snapshot is pending")
        button("移除附件：brief.md")!.performClick(nil)
        attachmentJob.completion(.success("Explain the project interfaces and dependencies using the attachments."))
        let afterAttachmentChange = try ChatStore(project: project).conversations.first { $0.id == second.id }!
        check(!view.hasRunning && input.string == longDraft && afterAttachmentChange.messages.count == 2 && afterAttachmentChange.draftAttachments?.count == 1
              && textVisible("内容已更改，请重新发送"),
              "changing attachments during translation rejects the stale send and keeps the remaining attachment and draft")
        try view.addAttachments([brief])
        button("发送消息")!.performClick(nil)
        translator.jobs.last!.completion(.failure(AppError.message("本机翻译未完成")))
        let retryAttachments = try ChatStore(project: project).conversations.first { $0.id == second.id }!.draftAttachments!
        check(input.string == longDraft && retryAttachments.count == 2 && button("重试翻译")?.isHidden == false,
              "translation failure returns a long draft and both attachments to the composer")
        settle()
        let retryRect = button("重试翻译")!.convert(button("重试翻译")!.bounds, to: view)
        check(retryRect.minX >= 0 && retryRect.maxX <= view.bounds.width && retryRect.width >= 60,
              "composer retry remains visible and clickable in a narrow split pane")
        try ChatUITests.snapshot(view, name: "translation-retry-compact")
        button("重试翻译")!.performClick(nil)
        let attachmentRetry = translator.jobs.last!
        check(input.string == longDraft && attachmentRetry.text == longDraft.trimmingCharacters(in: .whitespacesAndNewlines),
              "multi-attachment retry preserves the full original draft while translating")
        attachmentRetry.completion(.success("Explain the project using the two attached files."))
        let failedStart = try ChatStore(project: project).conversations.first { $0.id == second.id }!
        check(!view.hasRunning && input.string == longDraft && failedStart.messages.count == 2 && failedStart.draftAttachments == retryAttachments
              && button("重试翻译")?.isHidden == true && button("发送消息")?.isEnabled == true,
              "a successful translation followed by a blocked launch preserves the draft and attachments with ordinary send, not a misleading translation retry")
        button("发送消息")!.performClick(nil)
        translator.jobs.last!.completion(.failure(AppError.message("请重试")))
        draft("修改后的草稿。")
        check(button("重试翻译")?.isHidden == true && input.string == "修改后的草稿。",
              "editing after a failed translation clears the stale retry affordance")
        button("发送消息")!.performClick(nil)
        translator.jobs.last!.completion(.failure(AppError.message("请重试")))
        preference(0)
        check(button("重试翻译")?.isHidden == true && input.string == "修改后的草稿。",
              "disabling outgoing translation hides its retry without losing the draft")
        check(!window.isVisible, "translation UI checks stay offscreen")
        return count
    }
}
