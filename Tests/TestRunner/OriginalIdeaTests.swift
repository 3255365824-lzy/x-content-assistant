import Foundation
import XContentAssistantCore

func runOriginalIdeaTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/original-" + UUID().uuidString)
    let store = InteractionStore(root: root), batch = UUID().uuidString
    let text = "自助餐的仪式感，就是端着空盘绕了半天，最后又拿了一盘炒饭。"
    let idea = OriginalIdea(batchID: batch, topic: "吃喝", text: text)
    _ = try store.collect([InteractionPost(id: "98101", text: "旧回复记录保持原样。")])
    try check(try store.load().originalIdeas == nil, "old database needs no destructive migration")
    try check(try store.insertOriginals([idea]).count == 1, "original drafts need no fake post id or URL")
    try check(try store.insertOriginals([OriginalIdea(batchID: batch, topic: "吃喝", text: text)]).isEmpty, "different ids do not bypass text dedup")
    try check(try store.load().hotMaterials == nil && store.load().items.count == 1, "original generation preserves hot and reply queues")
    try store.editOriginal(idea.id, text: "我重新写了这一条，不要替我覆盖。")
    let edited = try store.load().originalIdeas![0]
    try check(edited.revision == 1 && edited.versions[0].text == text, "edits preserve generated initial candidate")
    try rejects("old handoff snapshot") { try store.handoffOriginal(idea) }
    try store.handoffOriginal(edited)
    try rejects("duplicate original handoff") { try store.handoffOriginal(edited) }
    let handed = try store.load().originalIdeas![0]
    try check(handed.handoffAt != nil && handed.text == edited.text, "handoff is not a fake API receipt")
    try rejects("editing handed-off original") { try store.editOriginal(idea.id, text: text) }
    _ = try store.updateOriginal(idea.id) { $0.handoffAt = nil; $0.archived = true }
    try rejects("editing archived original") { try store.editOriginal(idea.id, text: text) }
    _ = try store.updateOriginal(idea.id) { $0.archived = false }
    try store.editOriginal(idea.id, text: "")
    try check(try InteractionStore(root: root).load().originalIdeas![0].text.isEmpty, "manual clearing survives restart")
    var prefs = OriginalPreferences(); prefs.topics = []
    try rejects("empty topics") { try prefs.validate() }
    prefs.topics = ["吃喝"]; prefs.count = 5; try store.saveOriginalPreferences(prefs)
    try check(try store.load().originalPreferences == prefs, "original style/count preferences survive restart")
    for invalid in [OriginalRules.examples[0], "建议你学会放下手机，这说明我们要爱护自己。", "研究显示喝奶茶可以降低血糖。", "奶茶里添加了99种原料，这可不得了。", "原帖在 https://x.com/test 里面，快去看。"] {
        try rejects("copied, preaching or fabricated factual output") { try OriginalRules.validateGenerated(invalid) }
    }
    try check(OriginalRules.similar(text, text + "！"), "punctuation does not bypass near duplicate checks")
    try check(!OriginalRules.similar(text, "购物车最擅长的事，是把想省的钱凑成免邮。"), "different everyday angles are not false duplicates")
    print("original idea tests passed: migration, style, topic bounds, no fake evidence, similarity, edits, restart and manual handoff")
}

func runOriginalNetworkTests() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    var calls = 0
    MockURLProtocol.handler = { request in
        calls += 1
        guard request.url?.host == "127.0.0.1", request.url?.port == 11434 else { return (500, Data()) }
        let content = calls == 1 ? #"{"ideas":[{"topic":"吃喝","text":"自助餐的仪式感，就是端着空盘绕了半天，最后又拿了一盘炒饭。"}]}"# : #"{"reviews":[]}"#
        return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    let result = try await OriginalDraftClient(session: session).generate(preferences: OriginalPreferences(), existing: [])
    try check(result.ideas.isEmpty && !result.skipped.isEmpty && calls == 2, "missing review cannot approve an original or cause automatic retries")
    calls = 0
    MockURLProtocol.handler = { _ in calls += 1; return (500, Data("{}".utf8)) }
    do { _ = try await OriginalDraftClient(session: session).generate(preferences: OriginalPreferences(), existing: []); throw CheckFailure(message: "model failure accepted") }
    catch is InteractionError { }
    try check(calls == 1, "model failure is not retried behind user back")
    print("original network checks passed: loopback only, missing review held, no automatic retry")
}
