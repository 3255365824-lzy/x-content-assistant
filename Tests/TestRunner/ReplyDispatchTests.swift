import Foundation
import XContentAssistantCore

func qaBridgeFixture(_ operation: String) throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("qa-interactions")
    let store = InteractionStore(root: root)
    if operation == "seed" {
        _ = try store.collect([InteractionPost(id: "90091", text: "隔离 QA 原帖：AI 回答看起来流畅，也需要核对原始资料。仅用于测试，没有真实发布目标。", username: "qa_fixture", category: "AI", origin: "本地隔离验收")])
        if let item = try store.load().items.first(where: { $0.id == "90091" }), item.editable {
            try store.edit(item.id, text: "QA 测试：说得流畅不等于说得对，你会怎么核对原始出处？")
        }
        return
    }
    guard let item = try store.load().items.first(where: { $0.id == "90091" }), var job = item.dispatch, job.approval.testOnly else { throw InteractionError.invalid("只接受固定隔离目录里的 QA 批准") }
    let observation = ReplyPageObservation(account: job.approval.account, parentPostID: item.id, replyText: job.approval.text, sourceContextMatches: true)
    if operation == "uncertain" {
        job = try store.claimReply(job.id, testExecutor: true)
        _ = try store.commitReplyClick(job.id, token: job.claimToken!, observation: observation)
        try store.uncertainReply(job.id, token: job.claimToken!, reason: "QA 模拟网络超时：没有执行任何浏览器操作，禁止自动重发。")
    } else if operation == "receipt" {
        try store.recordBrowserReply(job.id, token: job.claimToken!, url: "https://x.com/\(job.approval.account)/status/90092", observation: observation)
    } else { throw InteractionError.invalid("未知 QA 操作") }
    try store.pulse(message: "QA 模拟执行器：没有真实网页发送")
}

func runReplyDispatchTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/dispatch-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InteractionStore(root: root), second = InteractionStore(root: root)
    let now = Date(timeIntervalSince1970: 1800000000)
    func create(_ id: String) throws -> InteractionItem {
        _ = try store.collect([InteractionPost(id: id, text: "AI 的回答需要核对原始资料，这是一个测试原帖。", username: "test_author", category: "AI")])
        try store.edit(id, text: "回答再流畅，也需要核对原始资料。")
        return try store.load().items.first { $0.id == id }!
    }
    let first = try create("70001")
    try check(first.dispatch == nil, "legacy draft is not implicitly approved")
    var stale = first; stale.replyText = "旧版本不能被确认。"
    try rejects("review snapshot changed") { _ = try store.approveReply(stale, account: "test_user", now: now) }
    var sourceChanged = first; sourceChanged.post.text += "已更改"
    try rejects("source changed") { _ = try store.approveReply(sourceChanged, account: "test_user", now: now) }
    try rejects("invalid sender") { _ = try store.approveReply(first, account: "nickname with space", now: now) }
    var job = try store.approveReply(first, account: "@Test_User", testOnly: true, now: now)
    try check(job.approval.account == "test_user" && job.approval.text == first.replyText, "exact text and normalized sender")
    try second.load().items[0].dispatch!.approval.validate()
    try rejects("duplicate confirm") { _ = try second.approveReply(first, account: "test_user", testOnly: true, now: now) }
    try rejects("edit after confirm") { try store.edit(first.id, text: "偷偷换文字") }
    try rejects("QA job refused by real executor") { _ = try second.claimReply(job.id, now: now) }
    job = try second.claimReply(job.id, testExecutor: true, now: now)
    try rejects("double claim") { _ = try store.claimReply(job.id, testExecutor: true, now: now) }
    let another = try create("70002")
    let pending = try store.approveReply(another, account: "test_user", testOnly: true, now: now)
    try rejects("parallel browser workers") { _ = try second.claimReply(pending.id, testExecutor: true, now: now) }
    let token = job.claimToken!
    let observed = ReplyPageObservation(account: "test_user", parentPostID: first.id, replyText: first.replyText, sourceContextMatches: true)
    for bad in [
        ReplyPageObservation(account: "wrong_user", parentPostID: first.id, replyText: first.replyText, sourceContextMatches: true),
        ReplyPageObservation(account: "test_user", parentPostID: "12", replyText: first.replyText, sourceContextMatches: true),
        ReplyPageObservation(account: "test_user", parentPostID: first.id, replyText: "意外的剪贴板内容", sourceContextMatches: true),
        ReplyPageObservation(account: "test_user", parentPostID: first.id, replyText: first.replyText, sourceContextMatches: false)
    ] { try rejects("wrong webpage observation") { _ = try store.commitReplyClick(job.id, token: token, observation: bad, now: now) } }
    try rejects("claim token wrong") { _ = try store.commitReplyClick(job.id, token: "wrong", observation: observed, now: now) }
    try store.cancelReply(first.id, now: now)
    try rejects("cancellation wins before click") { _ = try store.commitReplyClick(job.id, token: token, observation: observed, now: now) }
    try check(try store.load().items.first { $0.id == first.id }!.state == .ready, "cancel restores editable")
    job = try store.approveReply(first, account: "test_user", testOnly: true, now: now)
    try check(try store.load().items.first { $0.id == first.id }!.dispatchHistory?.count == 1, "old approval retained")
    job = try store.claimReply(job.id, testExecutor: true, now: now)
    let newToken = job.claimToken!
    _ = try store.commitReplyClick(job.id, token: newToken, observation: observed, now: now)
    try rejects("second irreversible click") { _ = try store.commitReplyClick(job.id, token: newToken, observation: observed, now: now) }
    try rejects("cancel after click boundary") { try store.cancelReply(first.id, now: now) }
    try rejects("cannot assert failure after click") { try store.blockReply(job.id, token: newToken, reason: "timeout", now: now) }
    _ = try second.reconcileReplies(now: now.addingTimeInterval(121))
    try check(try second.load().items.first { $0.id == first.id }!.dispatch?.state == .uncertain, "restart timeout becomes uncertain")
    try rejects("uncertain cannot claim") { _ = try second.claimReply(job.id, testExecutor: true, now: now.addingTimeInterval(122)) }
    try rejects("uncertain cannot reapprove") { _ = try second.approveReply(first, account: "test_user", testOnly: true, now: now) }
    try rejects("manual old reset cannot clear uncertain") { try second.resolveNotSent(first.id) }
    try rejects("receipt cannot be parent") { try store.recordBrowserReply(job.id, token: newToken, url: "https://x.com/test_user/status/70001", observation: observed) }
    try rejects("receipt must be sender") { try store.recordBrowserReply(job.id, token: newToken, url: "https://x.com/wrong/status/80001", observation: observed) }
    try store.recordBrowserReply(job.id, token: newToken, url: "https://x.com/test_user/status/80001", observation: observed, now: now.addingTimeInterval(130))
    try store.recordBrowserReply(job.id, token: newToken, url: "https://x.com/test_user/status/80001", observation: observed)
    try check(try second.load().items.first { $0.id == first.id }!.record?.kind == "simulated_browser_verified", "idempotent simulated receipt, not API success")
    try rejects("sent not reapproved") { _ = try store.approveReply(first, account: "test_user", now: now) }
    _ = try store.claimReply(pending.id, testExecutor: true, now: now)
    _ = try store.reconcileReplies(now: now.addingTimeInterval(301))
    try check(try store.load().items.first { $0.id == another.id }!.dispatch?.state == .blocked, "pre-click timeout blocked not requeued")
    let third = try create("70003")
    let expired = try store.approveReply(third, account: "test_user", testOnly: true, now: now)
    try rejects("expiry rejects claim") { _ = try store.claimReply(expired.id, testExecutor: true, now: now.addingTimeInterval(1801)) }
    _ = try store.reconcileReplies(now: now.addingTimeInterval(1801))
    try check(try store.load().items.first { $0.id == third.id }!.state == .ready, "expired requires new review")
    try store.pulse(message: "模拟执行器，未连接 X", now: now)
    try check(try second.load().executor?.message == "模拟执行器，未连接 X", "executor heartbeat persists")
    // Corrupting a saved approval cannot turn it into a new approved text.
    let rawPath = root.appendingPathComponent("interactions.json")
    let encoded = try String(contentsOf: rawPath, encoding: .utf8)
    try encoded.replacingOccurrences(of: job.approval.sha256, with: String(repeating: "0", count: 64)).write(to: rawPath, atomically: true, encoding: .utf8)
    let tampered = try store.load().items.first { $0.id == first.id }!.dispatch!
    try rejects("tampered hash") { try tampered.approval.validate() }
    print("reply dispatch checks passed: legacy, immutable approval, cancel race, single claim/click, account/text/context guards, restart timeout, receipt idempotency, QA isolation, expiry")
}
