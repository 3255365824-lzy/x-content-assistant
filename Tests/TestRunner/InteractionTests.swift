import Foundation
import XContentAssistantCore

func rejects(_ label: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckFailure(message: "not rejected: " + label)
}

func runInteractionStoreTests() throws {
    let source = "AI 生成的回答看起来很流畅，但使用前仍然需要核对原始资料。"
    let post = InteractionPost(id: "1234567890", text: source, category: "AI")
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".test-tmp/interactions-" + UUID().uuidString)
    let store = InteractionStore(root: root)
    defer { try? fm.removeItem(at: root) }
    let id = try InteractionRules.postID(from: "https://x.com/person/status/1234567890?s=20")
    try check(id == post.id, "X URL parsed and query stripped")
    for url in ["http://x.com/a/status/123", "https://x.com.evil.test/a/status/123", "https://x.com@evil.test/a/status/123", "https://x.com:443/a/status/123", "file:///123", "https://x.com/a/status/../x", "https://x.com/a/status/1/extra"] {
        try rejects("unsafe post URL") { _ = try InteractionRules.postID(from: url) }
    }
    try check(InteractionRules.category(source) == "AI", "AI category")
    try check(InteractionRules.category("周末睡眠补觉相关的医学话题") == "医学", "medical category")
    try check(InteractionRules.category("I paid for a chair") == "其他", "AI token boundary")
    let added = try store.collect([post, post]); try check(added == 1, "dedup within batch")
    try check(try store.collect([post]) == 0, "dedup across calls")
    try store.edit(post.id, text: "编辑后的回复：你一般怎么核对资料？")
    let candidate = ReplyCandidate(text: "流畅不代表准确。你通常先核对哪类资料？", quote: "使用前仍然需要核对原始资料", caveat: "原帖不是独立事实来源")
    try store.addCandidate(post.id, candidate: candidate, sourceText: source)
    var state = try store.load()
    try check(state.items[0].replyText.hasPrefix("编辑后的回复"), "candidate never overwrites edits")
    try check(state.items[0].candidates.count == 1, "candidate retained")
    let revisionBeforeClear = state.items[0].editRevision ?? 0
    try store.edit(post.id, text: "")
    try store.addCandidate(post.id, candidate: candidate, sourceText: source, expectedEditRevision: revisionBeforeClear)
    state = try store.load()
    try check(state.items[0].replyText.isEmpty && state.items[0].state == .unread && state.items[0].candidates.count == 2,
              "late model result preserves explicit clearing, retains candidate only")
    try check(!state.items[0].needsReplyPreparation, "cleared draft is not backfilled on restart")
    try rejects("unsupported number") { try InteractionRules.validateGenerated(text: "准确率 99% 吗？", quote: candidate.quote, source: source) }
    try rejects("noncontiguous quote") { try InteractionRules.validateGenerated(text: candidate.text, quote: "使用前一定要核对资料", source: source) }
    try rejects("medical instruction") { try InteractionRules.validateGenerated(text: "建议你停药。", quote: candidate.quote, source: source) }
    try rejects("long reply") { try store.edit(post.id, text: String(repeating: "药", count: 141)); _ = try store.markOpened(post.id, expectedText: String(repeating: "药", count: 141)) }
    try store.edit(post.id, text: candidate.text)
    try rejects("stale confirmation") { _ = try store.markOpened(post.id, expectedText: "old text") }
    try rejects("stale source snapshot") { _ = try store.markOpened(post.id, expectedText: candidate.text, expectedSource: "outdated source") }
    let reviewed = try store.markOpened(post.id, expectedText: candidate.text)
    try check(reviewed.state == .opened && reviewed.review?.text == candidate.text && reviewed.record == nil, "opening not publishing")
    let reloaded = InteractionStore(root: root)
    try check(try reloaded.load().items[0].state == .opened, "restart preserves uncertain handoff")
    try rejects("duplicate handoff") { _ = try reloaded.markOpened(post.id, expectedText: candidate.text) }
    try rejects("edit after handoff") { try reloaded.edit(post.id, text: "new") }
    try rejects("original URL as receipt") { try store.recordManual(post.id, url: post.url.absoluteString, finalText: candidate.text) }
    try store.resolveNotSent(post.id)
    _ = try store.markOpened(post.id, expectedText: candidate.text)
    try store.recordManual(post.id, url: "https://x.com/me/status/2234567890", finalText: "这是我在 X 最终编辑的内容。")
    state = try store.load()
    try check(state.items[0].state == .recorded && state.items[0].record?.kind == "manual_confirmed" && state.items[0].record?.finalText == "这是我在 X 最终编辑的内容。", "manual receipt distinct from API")
    try rejects("recorded duplicate blocked") { _ = try store.markOpened(post.id, expectedText: candidate.text) }
    try rejects("cannot reset recorded") { try store.resolveNotSent(post.id) }
    var changed = post; changed.text += " 更新原帖。"
    _ = try store.collect([changed]); try check(try store.load().items[0].post.text == source, "published source snapshot retained")
    var second = post; second.id = "2234567891"
    _ = try store.collect([second]); try store.edit(second.id, text: candidate.text)
    second.text += " 原帖被修改。"; _ = try store.collect([second])
    try check(try store.load().items.first { $0.id == second.id }?.state == .needsContext, "changed source invalidates review")
    let corruptRoot = root.appendingPathComponent("corrupt"); try fm.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
    let corrupt = corruptRoot.appendingPathComponent("interactions.json"); try Data("broken".utf8).write(to: corrupt)
    try rejects("corrupt store cannot overwrite") { _ = try InteractionStore(root: corruptRoot).collect([post]) }
    try check(try Data(contentsOf: corrupt) == Data("broken".utf8), "corrupt bytes preserved")
    let symlink = root.appendingPathComponent("alias"); try fm.createSymbolicLink(at: symlink, withDestinationURL: corruptRoot)
    try rejects("symbolic root") { _ = try InteractionStore(root: symlink).load() }
    let batchStore = InteractionStore(root: root.appendingPathComponent("batch"))
    let batch = (0..<50).map { index in
        let number = String(index)
        return PreparedReply(post: InteractionPost(id: String(80000 + index), text: source + " 样例 " + number, username: "test_author", category: "AI"), replyText: "样例 " + number + "：流畅不代表准确，你会先核对哪条依据？", quote: "使用前仍然需要核对原始资料", caveat: "仅为隔离测试")
    }
    let firstBatch = try batchStore.importPrepared(batch)
    try check(firstBatch.addedIDs.count == 50 && firstBatch.remainingCapacity == 950, "batch imports 50 drafts")
    let batchDB = try batchStore.load()
    try check(batchDB.items.allSatisfy { $0.state == .ready && $0.dispatch == nil && $0.review == nil && $0.record == nil }, "batch is never sending approval")
    try batchStore.edit("80000", text: "这是用户保留的编辑，不得覆盖。")
    let repeated = try batchStore.importPrepared(batch)
    try check(repeated.addedIDs.isEmpty && repeated.skippedIDs.count == 50, "repeated batch is idempotent")
    try check(try batchStore.load().items.first { $0.id == "80000" }?.replyText == "这是用户保留的编辑，不得覆盖。", "import preserves edits")
    _ = try batchStore.markOpened("80001", expectedText: batch[1].replyText)
    _ = try batchStore.importPrepared([batch[1]])
    try check(try batchStore.load().items.first { $0.id == "80001" }?.state == .opened, "import preserves uncertain opened state")
    var duplicateText = batch[2]; duplicateText.post.id = "90000"
    try check(try batchStore.importPrepared([duplicateText]).addedIDs.isEmpty, "identical reply text skipped across different posts")
    var invalid = batch[0]; invalid.post.id = "90001"; invalid.quote = "根本不存在的依据"
    let beforeInvalid = try Data(contentsOf: batchStore.root.appendingPathComponent("interactions.json"))
    try rejects("invalid evidence rejects whole batch") { _ = try batchStore.importPrepared([duplicateText, invalid]) }
    try check(try Data(contentsOf: batchStore.root.appendingPathComponent("interactions.json")) == beforeInvalid, "invalid import keeps exact previous bytes")
    try rejects("oversized batch") { _ = try batchStore.importPrepared(batch + [batch[0]]) }
    invalid = batch[0]; invalid.observedAt = Date().addingTimeInterval(-90000)
    try rejects("stale observation") { _ = try batchStore.importPrepared([invalid]) }
    invalid = batch[0]; invalid.post.username = "作者未提供"
    try rejects("missing actual author") { _ = try batchStore.importPrepared([invalid]) }
    print("interaction store checks passed")
}

func runInteractionNetworkTests() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let client = XAPIClient(session: session, apiBaseURL: URL(string: "https://mock.local")!)
    var outboundWrites = 0, reads = 0
    MockURLProtocol.handler = { request in
        if request.httpMethod != "GET" { outboundWrites += 1 }
        reads += 1
        let correct = request.url?.path == "/2/users/42/timelines/reverse_chronological" && URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "max_results", value: "25")) == true
        guard correct else { return (400, Data("{}".utf8)) }
        return (200, Data(#"{"data":[{"id":"123","author_id":"43","text":"short original","note_tweet":{"text":"AI 原帖长正文，包含更多完整的原始资料。"}},{"id":"124","author_id":"42","text":"AI 自己的帖子，应该排除"}],"includes":{"users":[{"id":"43","username":"other_user"}]},"meta":{"result_count":2}}"#.utf8))
    }
    let posts = try await client.followingPosts(accountID: "42", accessToken: "mock-token")
    try check(posts.count == 1 && posts[0].text.hasPrefix("AI 原帖长正文") && posts[0].username == "other_user" && posts[0].sourceAccountID == "42", "read feed excludes own and uses full note text")
    try check(outboundWrites == 0 && reads == 1, "feed read-only and bounded one page")
    for code in [401, 403, 402, 429, 500] {
        var count = 0; MockURLProtocol.handler = { _ in count += 1; return (code, Data("{}".utf8)) }
        do { _ = try await client.followingPosts(accountID: "42", accessToken: "mock"); throw CheckFailure(message: "feed error not surfaced") }
        catch is XClientError { }
        try check(count == 1, "no background retry on feed error")
    }
    MockURLProtocol.handler = { _ in (200, Data(#"{"meta":{"result_count":0}}"#.utf8)) }
    let empty = try await client.followingPosts(accountID: "42", accessToken: "mock")
    try check(empty.isEmpty, "empty feed")
    MockURLProtocol.handler = { _ in (200, Data(#"{"errors":[{"detail":"denied"}]}"#.utf8)) }
    do { _ = try await client.followingPosts(accountID: "42", accessToken: "mock"); throw CheckFailure(message: "partial feed accepted") } catch is InteractionError { }
    var modelCalls = 0
    MockURLProtocol.handler = { request in
        modelCalls += 1
        guard request.url?.host == "127.0.0.1", request.url?.path == "/api/chat" else { return (500, Data()) }
        if modelCalls == 2 { return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": #"{"supported":true,"reason":""}"#]])) }
        let reply = #"{"reply":"流畅不代表准确，你通常怎么核对原始资料？","quote":"使用前仍然需要核对原始资料","caution":"请核对原帖上下文","needs_context":false}"#
        return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": reply]]))
    }
    let generated = try await LocalReplyClient(session: session).generate(post: InteractionPost(id: "123", text: "AI 生成的回答看起来很流畅，但使用前仍然需要核对原始资料。", category: "AI"), tone: "具体提问")
    try check(generated.quote == "使用前仍然需要核对原始资料" && modelCalls == 2, "local reply, quote validation and separate review")
    var rejectedCalls = 0
    MockURLProtocol.handler = { _ in
        rejectedCalls += 1
        let content = rejectedCalls == 1 ? #"{"reply":"标题作者都对，链接不对。","quote":"标题作者写得像模像样","caution":"","needs_context":false}"# : #"{"supported":false,"reason":"原帖没有确认标题作者正确"}"#
        return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    do { _ = try await LocalReplyClient(session: session).generate(post: InteractionPost(id: "123", text: "标题作者写得像模像样，打开却查不到这篇论文。")); throw CheckFailure(message: "unsupported natural rewrite accepted") } catch is InteractionError { }
    try check(rejectedCalls == 2, "rejected review neither generates again nor retries automatically")
    let echoPost = InteractionPost(id: "234", text: "流畅的回答也需要核对原始资料。", category: "AI")
    let echoJSON = #"{"reply":"流畅的回答也需要核对原始资料。","quote":"需要核对原始资料","caution":"","needs_context":false}"#
    let repairJSON = #"{"reply":"说得再顺，也得翻翻出处。","quote":"需要核对原始资料","caution":"","needs_context":false}"#
    func envelope(_ content: String) -> Data { try! JSONSerialization.data(withJSONObject: ["message": ["content": content]]) }
    var echoCalls = 0, onlyLoopback = true
    MockURLProtocol.handler = { request in
        onlyLoopback = onlyLoopback && request.url?.host == "127.0.0.1"
        echoCalls += 1
        return (200, envelope(echoCalls == 1 ? echoJSON : echoCalls == 2 ? repairJSON : #"{"supported":true,"reason":""}"#))
    }
    let recovered = try await LocalReplyClient(session: session).generate(post: echoPost)
    try check(recovered.text == "说得再顺，也得翻翻出处。" && echoCalls == 3, "one echo repair then independent fact review")
    try check(onlyLoopback, "echo recovery never contacts X")
    echoCalls = 0
    MockURLProtocol.handler = { _ in echoCalls += 1; return (200, envelope(echoJSON)) }
    do { _ = try await LocalReplyClient(session: session).generate(post: echoPost); throw CheckFailure(message: "repeated echo accepted") }
    catch ReplyWritingError.echoRetryExhausted { }
    try check(echoCalls == 2, "repeated echo stops after exactly one rewrite")
    echoCalls = 0
    do { _ = try await LocalReplyClient(session: session).generate(post: echoPost, recoveringEcho: true); throw CheckFailure(message: "legacy repeated echo accepted") }
    catch ReplyWritingError.echoRetryExhausted { }
    try check(echoCalls == 1, "legacy echo recovery gets only its one remaining attempt")
    echoCalls = 0
    MockURLProtocol.handler = { _ in echoCalls += 1; return (503, Data()) }
    do { _ = try await LocalReplyClient(session: session).generate(post: echoPost); throw CheckFailure(message: "model server error ignored") }
    catch is InteractionError { }
    try check(echoCalls == 1, "server error does not trigger rewrite")
    echoCalls = 0
    MockURLProtocol.handler = { _ in echoCalls += 1; return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": #"{"reply":"","quote":"","caution":"个人求医","needs_context":true}"#]])) }
    do { _ = try await LocalReplyClient(session: session).generate(post: InteractionPost(id: "123", text: "我最近不舒服，请帮我判断吃什么药物。"), tone: "具体提问"); throw CheckFailure(message: "needs context ignored") } catch is InteractionError { }
    try check(echoCalls == 1, "medical missing-context response never rewritten automatically")
    echoCalls = 0
    do { _ = try await LocalReplyClient(session: session).generate(post: InteractionPost(id: "123", text: "听说这个视频非常刺激，是真的吗？")); throw CheckFailure(message: "unseen media accepted") } catch is InteractionError { }
    try check(echoCalls == 0, "unseen media is blocked before a model can guess")
    print("interaction network mocks passed; no real X requests")
}

func liveReplySmoke() async throws {
    let sources = [
        InteractionPost(id: "90001", text: "每次拿到体检报告，专业名词还没看懂，先被一排箭头吓了一跳。", category: "医学"),
        InteractionPost(id: "90002", text: "让 AI 找论文，标题、作者、期刊都写得像模像样，结果点开链接根本没有这篇。", category: "AI"),
        InteractionPost(id: "90003", text: "这个语音输入最省事的地方，是不在输入框里也能说，说完自动存成 txt 文件。", category: "AI"),
        InteractionPost(id: "90004", text: "Claude 封号后，默认 agent 换成了 Opencode + DeepSeek。", category: "AI")
    ]
    for post in sources {
        do {
            let reply = try await LocalReplyClient().generate(post: post)
            let data = try JSONEncoder().encode(reply)
            print("LIVE LOCAL \(post.id) \(post.category) [\(reply.text.count) chars]: \(String(decoding: data, as: UTF8.self))")
        } catch let error as InteractionError {
            print("LIVE LOCAL \(post.id) NEEDS_REVIEW: \(error.localizedDescription)")
        }
    }
    let rewritten = try await LocalReplyClient().generate(post: sources[2], currentReply: "最吸引我的是不用先想好存哪儿，说完就有个文件。中英混输里的产品名、缩写也能稳住吗？真能少改这些小地方，才会愿意天天用。", recentReplies: ["不用找输入框这点真省事。"])
    print("LIVE LOCAL REWRITE: \(String(decoding: try JSONEncoder().encode(rewritten), as: UTF8.self))")
}
