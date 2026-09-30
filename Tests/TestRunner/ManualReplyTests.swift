import Foundation
import XContentAssistantCore

func runManualReplyTests() throws {
    for state in ReplyState.allCases {
        try check(ReplyListFilter.pending.includes(state) == ![.opened, .recorded, .sent, .skipped].contains(state), "pending excludes handoffs and completed records")
        try check(ReplyListFilter.readyToSend.includes(state) == (state == .ready), "ready-to-send excludes unwritten, skipped, uncertain and handed-off records")
        try check(ReplyListFilter.handled.includes(state) == [.opened, .recorded, .sent].contains(state), "handled includes handoffs, not uncertain legacy jobs")
        try check(ReplyListFilter.needsReview.includes(state) == (state == .uncertain), "handoff no longer requires receipt or review")
    }
    try check(ReplyState.opened.label == "已处理" && !ReplyListFilter.replied.includes(.opened), "handled never means published")
    try check(ReplyState.ready.label == "待发送" && ReplyState.ready.rawValue == "ready", "ready label changes without data migration or approval")
    try check(ReplyListFilter.allCases.map(\.rawValue) == ["待处理", "待发送", "已处理", "待核对", "已回复", "已跳过", "全部"], "ready-to-send follows pending in native status menu")
    let text = "中文 & + # ? 👨‍👩‍👧‍👦\n下一行：50% 不等于结论。"
    let url = try ManualReplyRules.intentURL(postID: "123456", text: text)
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    try check(components.host == "x.com" && components.scheme == "https" && components.path == "/intent/tweet", "official user-driven reply intent")
    try check(components.queryItems?.count == 2 && components.queryItems?.first(where: { $0.name == "text" })?.value == text && components.queryItems?.first(where: { $0.name == "in_reply_to" })?.value == "123456", "exact encoded text and reply target")
    try check(components.percentEncodedQuery?.contains("%2B") == true, "plus not silently converted to a space")
    try rejects("invalid post ID") { _ = try ManualReplyRules.intentURL(postID: "123&text=wrong", text: text) }
    try rejects("too long") { _ = try ManualReplyRules.intentURL(postID: "123", text: String(repeating: "医", count: 141)) }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/manual-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InteractionStore(root: root)
    func seed(_ id: String) throws -> InteractionItem {
        _ = try store.collect([InteractionPost(id: id, text: "原帖：AI 回答需要核对资料，不能只看文字流畅。", username: "fixture", category: "AI")])
        try store.edit(id, text: "流畅不等于准确，关键还是核对原始依据。")
        return try store.load().items.first { $0.id == id }!
    }
    let queued = try seed("91001")
    let queuedJob = try store.approveReply(queued, account: "tester", testOnly: true)
    let uncertain = try seed("91002")
    var uncertainJob = try store.approveReply(uncertain, account: "tester", testOnly: true)
    uncertainJob = try store.claimReply(uncertainJob.id, testExecutor: true)
    _ = try store.commitReplyClick(uncertainJob.id, token: uncertainJob.claimToken!, observation: ReplyPageObservation(account: "tester", parentPostID: uncertain.id, replyText: uncertain.replyText, sourceContextMatches: true))
    let oldOpened = try seed("91003")
    _ = try store.markOpened(oldOpened.id, expectedText: oldOpened.replyText)
    let reopenedStore = InteractionStore(root: root)
    let persistedHandoff = try reopenedStore.load().items.first { $0.id == oldOpened.id }!
    try check(ReplyListFilter.handled.includes(persistedHandoff.state) && persistedHandoff.record == nil && persistedHandoff.review?.text == oldOpened.replyText, "handled survives restart with exact text and no fake receipt")
    let migrated = try store.loadForManualReplies()
    try check(migrated.manualRepliesOnly == true && migrated.executor == nil, "manual-only store flag")
    let ready = migrated.items.first { $0.id == queued.id }!
    try check(ready.state == .ready && ready.replyText == queued.replyText && ready.dispatch?.state == .cancelled && ready.dispatch?.approval == queuedJob.approval, "queued approval cancelled and preserved without altering text")
    try check(migrated.items.first { $0.id == uncertain.id }?.state == .uncertain && migrated.items.first { $0.id == oldOpened.id }?.state == .opened, "uncertain and old handoff never reset to sendable")
    try rejects("no new automatic approval") { _ = try store.approveReply(ready, account: "tester") }
    try rejects("no background claim") { _ = try store.claimReply(queuedJob.id, testExecutor: true) }
    let before = try Data(contentsOf: root.appendingPathComponent("interactions.json"))
    _ = try store.loadForManualReplies()
    try check(try Data(contentsOf: root.appendingPathComponent("interactions.json")) == before, "migration idempotent and read refresh does not rewrite store")
    try store.recordManual(uncertain.id, url: "https://x.com/tester/status/92002", finalText: uncertain.replyText)
    let recorded = try store.load().items.first { $0.id == uncertain.id }!
    try check(recorded.record?.kind == "manual_confirmed" && recorded.dispatch == nil && recorded.dispatchHistory?.count == 1, "explicit manual receipt keeps previous ambiguous evidence")
    try store.resolveNotSent(oldOpened.id)
    let restored = try store.load().items.first { $0.id == oldOpened.id }!
    try check(ReplyListFilter.pending.includes(restored.state) && ReplyListFilter.readyToSend.includes(restored.state) && !ReplyListFilter.handled.includes(restored.state) && restored.replyText == oldOpened.replyText && restored.record == nil, "explicit undo restores original editor without publishing")
    try store.edit(restored.id, text: " \n ")
    let emptied = try store.load().items.first { $0.id == restored.id }!
    try check(!ReplyListFilter.readyToSend.includes(emptied.state) && ReplyListFilter.pending.includes(emptied.state), "clearing reply removes it from ready-to-send without losing source")
    print("manual reply tests passed: handled filters, restart, undo, encoding, one-click, source protection, legacy migration, no executor, idempotency, manual receipts")
}
