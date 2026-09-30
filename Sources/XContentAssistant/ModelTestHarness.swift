#if APP_TESTS
import Foundation
import AppKit
import XContentAssistantCore

final class MemoryTokens: TokenStore, @unchecked Sendable {
    var values: [String: String] = ["accessToken": "test-token", "refreshToken": "test-refresh", "expiresAt": String(Date().addingTimeInterval(3600).timeIntervalSince1970)]
    func save(_ value: String, key: String) { values[key] = value }
    func load(key: String) -> String? { values[key] }
    func delete(key: String) { values.removeValue(forKey: key) }
}
final class AppMock: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
enum Failure: Error { case check(String) }
func require(_ value: Bool, _ label: String) throws { if !value { throw Failure.check(label) } }
func requestBody(_ request: URLRequest) throws -> [String: Any] {
    if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
    guard let stream = request.httpBodyStream else { return [:] }; stream.open(); defer { stream.close() }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// URLProtocol callbacks run outside MainActor; keep nested collection closures nonisolated too.
func originalMockReview(_ candidates: String) throws -> String {
    let values = try JSONSerialization.jsonObject(with: Data(candidates.utf8)) as! [[String: String]]
    let reviews = values.map { ["id": $0["id"]!, "acceptable": true, "reason": ""] as [String: Any] }
    return String(decoding: try JSONSerialization.data(withJSONObject: ["reviews": reviews]), as: UTF8.self)
}

@MainActor func runModelTests() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AppMock.self]
    let session = URLSession(configuration: config)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/app-" + UUID().uuidString)
    let runtime = LocalRuntimeClient(runtimeRoot: root, session: session)
    let x = XAPIClient(session: session, apiBaseURL: URL(string: "https://mock.invalid")!)
    let tokens = MemoryTokens()
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    var stored = DraftManifest(id: "test-draft", category: .ai, angle: "观点", postText: "旧文字", sourceRelativePath: "AI/source.md")
    var postCount = 0, uploadCount = 0, finalPost = "", refreshed = 0, userID = "42", status = 200
    var timeout = false, savedBeforePublish = false
    AppMock.handler = { request in
        let path = request.url!.path
        if path == "/2/oauth2/token" { refreshed += 1; return (200, Data("{\"access_token\":\"new-token\",\"refresh_token\":\"new-refresh\",\"expires_in\":7200}".utf8)) }
        if path == "/2/users/me" { return (200, Data("{\"data\":{\"id\":\"\(userID)\",\"username\":\"mock_user\"}}".utf8)) }
        if path.hasSuffix("/update") {
            let body = try requestBody(request); stored.postText = body["postText"] as! String; stored.sourceURL = body["sourceURL"] as? String; stored.includeSourceURL = body["includeSourceURL"] as? Bool ?? false; stored.revision += 1; savedBeforePublish = true
            return (200, try encoder.encode(stored))
        }
        if path.hasSuffix("/begin-publishing") {
            try require(savedBeforePublish, "must save edits first")
            let body = try requestBody(request); try require(body["expectedRevision"] as? Int == stored.revision, "revision snapshot")
            guard stored.status == .queued || stored.status == .failed else { return (409, Data()) }; stored.status = .publishing; return (200, try encoder.encode(stored))
        }
        if path == "/2/media/upload" { uploadCount += 1; return (200, Data("{\"data\":{\"id\":\"media\"}}".utf8)) }
        if path == "/2/tweets" { postCount += 1; finalPost = try requestBody(request)["text"] as? String ?? ""; if timeout { throw URLError(.timedOut) }; return (status, Data("{\"data\":{\"id\":\"123\",\"text\":\"ok\"}}".utf8)) }
        if path.hasSuffix("/mark-published") { stored.status = .published; return (200, try encoder.encode(stored)) }
        if path.hasSuffix("/needs-confirmation") { stored.status = .needsConfirmation; return (200, try encoder.encode(stored)) }
        if path.hasSuffix("/failed") { stored.status = .failed; return (200, try encoder.encode(stored)) }
        return (404, Data())
    }
    let suiteName = "com.longzhengyang.x-content-assistant.test-" + UUID().uuidString
    let prefs = UserDefaults(suiteName: suiteName)!
    defer { prefs.removePersistentDomain(forName: suiteName) }
    let model = AppModel(runtime: runtime, xClient: x, keychain: tokens, autoStart: false, testPreferences: prefs)
    model.clientID = "mock-client"
    let editor = model.editor(stored); editor.text = "编辑后的最终文案"; editor.sourceURL = "https://example.org/source"; editor.includeURL = true; editor.changed()
    try require(await editor.flush(), "edited save")
    await model.preparePublish(editor)
    guard let preview = model.pendingPublish else { throw Failure.check("confirmation snapshot") }
    try require(preview.finalText == "编辑后的最终文案\nhttps://example.org/source", "confirmation uses edits and URL")
    await model.publish(preview)
    try require(finalPost == preview.finalText && postCount == 1 && stored.status == .published, "exact final snapshot transmitted")
    await model.publish(preview)
    try require(postCount == 1, "duplicate blocked by server state")

    for responseStatus in [401, 403, 402, 429, 500] {
        stored.status = .queued; status = responseStatus; timeout = false
        let count = postCount; await model.publish(preview)
        try require(postCount == count + 1, "no automatic retry HTTP \(responseStatus)")
        try require(stored.status == (responseStatus >= 500 ? .needsConfirmation : .failed), "HTTP classification \(responseStatus)")
    }
    stored.status = .queued; status = 200; timeout = true
    let count = postCount; await model.publish(preview); await model.publish(preview)
    try require(postCount == count + 1 && stored.status == .needsConfirmation, "timeout no second post")
    stored.status = .queued; userID = "other"; timeout = false
    let previous = postCount; await model.publish(preview); try require(postCount == previous, "account changed requires reconfirmation")
    userID = "42"; tokens.values["expiresAt"] = "0"
    _ = try await model.authorizedAccount(); try require(refreshed == 1 && tokens.load(key: "refreshToken") == "new-refresh", "expired access refresh and rotation")
    model.disconnectX(); try require(tokens.load(key: "accessToken") == nil, "disconnect clears tokens")
    model.schedule.enabled = false
    stored.status = .queued; stored.plannedAt = Date(); model.drafts = [stored]
    await model.tick(); try require(model.dueDraftID == stored.id, "planned time reminds without posting")
    model.dueDraftID = nil; await model.tick(); try require(model.dueDraftID == nil, "same reminder not repeated")
    stored.plannedAt = Date(); model.drafts = [stored]
    await model.tick(); try require(model.dueDraftID == stored.id, "rescheduled draft reminds again")
    // Upload is separately tested by the core protocol mock. No image is needed for this snapshot test.
    try require(uploadCount == 0, "no unexpected upload")
    print("app model tests passed: edited snapshot, autosave, URL, duplicate, five HTTP classes, timeout, account switch, refresh, token store")
    let interactionRoot = root.appendingPathComponent("reply-ui")
    var openedURLs: [URL] = []
    let center = InteractionModel(root: interactionRoot, generator: LocalReplyClient(session: session), synchronousInitialLoad: true, browserOpener: { url in openedURLs.append(url) })
    try require(center.tone == "随口一句", "new sessions default to natural replies")
    try require(center.extensionDirectory == interactionRoot.deletingLastPathComponent().appendingPathComponent("EdgeExtension"), "extension path follows paired data rather than movable app bundle")
    let styleFixture = #"{"schema":1,"observations":[{"id":"model-test-style","category":"AI","name":"具体接话","whenUseful":"操作体验","pattern":"只接一个具体点","avoid":"不要编个人经历","parentURL":"https://x.com/test/status/94301","replyURLs":["https://x.com/test/status/94302"],"observedAt":"2026-09-01T00:00:00Z","enabled":true}]}"#
    try Data(styleFixture.utf8).write(to: interactionRoot.appendingPathComponent("reply-style.json"), options: .atomic)
    try require(!center.autoRefresh, "automatic paid reads off at startup")
    try require(center.importPost(url: "https://x.com/test/status/987654", text: "AI 测试原帖：流畅的回答也需要核对原始资料。", category: "AI"), "manual import usable without X")
    center.saveText("987654", text: "这是我人工修改后的回复。")
    try require(center.items.filter { ReplyListFilter.readyToSend.includes($0.state) }.map(\.id) == ["987654"], "manual writing enters ready-to-send without publication")
    let reloaded = InteractionModel(root: interactionRoot, synchronousInitialLoad: true)
    try require(reloaded.items.first?.replyText == "这是我人工修改后的回复。", "reply edit restored after restart")
    var replyCalls = 0
    var expectStyle = true
    AppMock.handler = { request in
        try require(request.url?.host == "127.0.0.1" && request.url?.path == "/api/chat", "reply generator only local model")
        let body = try requestBody(request)
        let messages = body["messages"] as! [[String: String]]
        let source = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        replyCalls += 1
        if source["replyText"] != nil {
            try require(source["replyText"] == "就怕它错得还挺像那么回事。" && source["sourceText"]?.contains("核对原始资料") == true, "local review gets exact generated candidate and source")
            try require(source["styleNotes"] == nil, "style observations never become factual review evidence")
            return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": #"{"supported":true,"reason":""}"#]]))
        }
        try require(source["tone"] == "随口一句" && source["draftToRewrite"] == "这是我人工修改后的回复。", "natural rewrite gets actual edited draft as data")
        try require(expectStyle ? source["styleNotes"]?.contains("只接一个具体点") == true : source["styleNotes"] == "", "style toggle controls use of saved observations")
        try require(!messages[0]["content"]!.contains("最后必须有"), "request does not force a concluding question")
        return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": #"{"reply":"就怕它错得还挺像那么回事。","quote":"流畅的回答也需要核对原始资料","caution":"","needs_context":false}"#]]))
    }
    let original = center.items[0]; center.generate(original); center.generate(original)
    let deadline = Date().addingTimeInterval(5)
    while center.generatingID != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(replyCalls == 2 && center.items[0].candidates.count == 1, "one local generation plus review, double click still blocked")
    try require(center.items[0].replyText == "这是我人工修改后的回复。", "model candidate preserves edited reply")
    try require(center.styleReferenceMessage.contains("1 条浏览观察"), "UI reports actually loaded observations, not training progress")
    try require(center.items[0].candidates[0].text == "就怕它错得还挺像那么回事。" && center.items[0].candidates[0].caveat.isEmpty, "short declarative candidate accepted without forced warning")
    expectStyle = false; center.useStyleReference = false; center.generate(center.items[0])
    let disabledDeadline = Date().addingTimeInterval(5)
    while center.generatingID != nil && Date() < disabledDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(replyCalls == 4 && center.styleReferenceMessage.contains("不使用"), "style reference can be disabled inside App")
    try require(center.items[0].replyText == "这是我人工修改后的回复。", "optional style never overwrites editor")
    var stale = center.items[0]; stale.replyText = "旧版本的文字"
    await center.goReply(stale)
    try require(openedURLs.isEmpty && center.error != nil, "stale editor cannot open browser")
    let reviewed = center.items[0]
    await center.goReply(reviewed)
    let query = URLComponents(url: openedURLs[0], resolvingAgainstBaseURL: false)!.queryItems!
    try require(query.first { $0.name == "text" }?.value == reviewed.replyText && query.first { $0.name == "in_reply_to" }?.value == reviewed.id, "one click uses current edited text and parent")
    try require(center.items[0].state == .opened && center.items[0].dispatch == nil && center.items[0].record == nil, "handoff neither approves nor records publication")
    try require(center.items.filter { ReplyListFilter.readyToSend.includes($0.state) }.isEmpty, "handoff leaves ready-to-send immediately")
    let pendingIDs = center.items.filter { ReplyListFilter.pending.includes($0.state) }.map(\.id)
    center.selectVisible(pendingIDs)
    try require(pendingIDs.isEmpty && center.selectedID == nil, "last handoff disappears from pending including stale detail selection")
    let handledIDs = center.items.filter { ReplyListFilter.handled.includes($0.state) }.map(\.id)
    center.selectVisible(handledIDs)
    try require(handledIDs == [reviewed.id] && center.selectedID == reviewed.id, "handled filter finds handoff without a receipt")
    center.selectVisible(["next-visible", "last-visible"])
    try require(center.selectedID == "next-visible", "removed selection advances to next filtered row")
    center.selectedID = "last-visible"; center.selectVisible(["next-visible", "last-visible"])
    try require(center.selectedID == "last-visible", "refresh preserves an existing visible selection")
    await center.goReply(reviewed)
    try require(openedURLs.count == 1, "double click does not reopen composer")
    center.resolveNotSent("987654")
    try require(center.items[0].state == .ready, "explicit not sent returns editor")
    let failedCenter = InteractionModel(root: interactionRoot, synchronousInitialLoad: true, browserOpener: { _ in throw Failure.check("simulated browser failure") })
    await failedCenter.goReply(failedCenter.items[0])
    try require(failedCenter.items[0].state == .opened && failedCenter.error?.contains("已处理") == true && failedCenter.items[0].record == nil, "browser failure reports where handoff was stored, never fake success or retry")
    center.autoRefresh = true; center.nextRefresh = Date(); center.stop()
    try require(!center.autoRefresh && !center.shouldRefresh, "stop cancels polling")
    center.discoveryPolicy.limit = 50; center.discoveryPolicy.followerThreshold = 50_000; center.autoDraft = false
    let preferencesReload = InteractionModel(root: interactionRoot, synchronousInitialLoad: true)
    try require(preferencesReload.preferencesLoaded && preferencesReload.discoveryPolicy.limit == 50 && preferencesReload.discoveryPolicy.followerThreshold == 50_000 && !preferencesReload.autoDraft && !preferencesReload.useStyleReference, "App settings restored without starting discovery")
    try require(preferencesReload.discoveryJob == nil && !preferencesReload.autoRefresh, "restored settings are not a browsing or sending request")
    let batchRoot = root.appendingPathComponent("reply-batches")
    let batch = InteractionModel(root: batchRoot, generator: LocalReplyClient(session: session), synchronousInitialLoad: true)
    for id in ["990001", "990002", "990003"] {
        try require(batch.importPost(url: "https://x.com/test/status/\(id)", text: "流畅的回答也需要核对原始资料。", category: "AI"), "batch fixture imported")
    }
    var batchCalls = 0
    AppMock.handler = { request in
        try require(request.url?.host == "127.0.0.1", "batch writes stay local")
        batchCalls += 1
        let body = try requestBody(request), messages = body["messages"] as! [[String: String]]
        let source = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        let content = source["replyText"] == nil ? #"{"reply":"就怕它错得还挺像那么回事。","quote":"流畅的回答也需要核对原始资料","caution":"","needs_context":false}"# : #"{"supported":true,"reason":""}"#
        return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    batch.generateDiscovered(["990001"])
    batch.generateDiscovered(["990001", "990002", "990003"])
    batch.saveText("990003", text: "这条我已经自己写了，批量任务别动它。")
    let batchDeadline = Date().addingTimeInterval(5)
    while (batch.replyQueueCount > 0 || batch.generatingID != nil) && Date() < batchDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(batchCalls == 4 && batch.items.filter { !$0.candidates.isEmpty }.count == 2, "overlapping batches append, deduplicate and run exactly once")
    try require(batch.items.filter { ReplyListFilter.readyToSend.includes($0.state) }.count == 3, "automatic drafts and manual edits enter ready-to-send")
    try require(batch.items.first { $0.id == "990003" }?.replyText == "这条我已经自己写了，批量任务别动它。", "queued generation rechecks and preserves later manual edit")
    try require(batch.replyBatchMessage?.contains("1 条已编辑") == true, "batch progress explains skipped manual edits")
    for id in ["990004", "990005"] { _ = batch.importPost(url: "https://x.com/test/status/\(id)", text: "流畅的回答也需要核对原始资料。", category: "AI") }
    batch.generateDiscovered(["990004", "990005"]); batch.stop()
    try await Task.sleep(for: .milliseconds(30))
    try require(batchCalls == 4 && batch.replyQueueCount == 0 && batch.items.first { $0.id == "990004" }?.state == .unread, "stop before processing clears queue without model call or losing sources")
    batch.generateDiscovered([])
    let backfillDeadline = Date().addingTimeInterval(5)
    while batch.preparingReplies && Date() < backfillDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(batchCalls == 8 && batch.missingReplyCount == 0, "zero newly fetched IDs still backfill untouched old records")

    let recoverRoot = root.appendingPathComponent("reply-recovery")
    let recovery = InteractionModel(root: recoverRoot, generator: LocalReplyClient(session: session), synchronousInitialLoad: true)
    _ = recovery.importPost(url: "https://x.com/test/status/991001", text: "流畅的回答也需要核对原始资料。", category: "AI")
    _ = try recovery.store.update("991001") { $0.state = .needsContext; $0.note = ReplyWritingRules.legacyEchoMessage }
    recovery.reload()
    var recoveryCalls = 0
    AppMock.handler = { request in
        recoveryCalls += 1
        let messages = try requestBody(request)["messages"] as! [[String: String]]
        try require(messages[0]["content"]!.contains("本次只重写一次"), "legacy recovery uses repair instructions")
        return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": #"{"reply":"流畅的回答也需要核对原始资料。","quote":"需要核对原始资料","caution":"","needs_context":false}"#]]))
    }
    recovery.prepareMissingReplies(); recovery.prepareMissingReplies()
    let recoveryDeadline = Date().addingTimeInterval(5)
    while recovery.preparingReplies && Date() < recoveryDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(recoveryCalls == 1 && recovery.items[0].preparationFailure == .echoRetryExhausted, "double backfill keeps one bounded legacy rewrite")
    let recoveryRestart = InteractionModel(root: recoverRoot, generator: LocalReplyClient(session: session), synchronousInitialLoad: true)
    recoveryRestart.resumeReplyPreparation()
    try await Task.sleep(for: .milliseconds(30))
    try require(recoveryCalls == 1 && recoveryRestart.missingReplyCount == 0 && !recoveryRestart.preparingReplies, "persisted exhausted reply is not retried on restart")

    let startupRoot = root.appendingPathComponent("reply-startup")
    let startupStore = InteractionStore(root: startupRoot)
    _ = try startupStore.collect([InteractionPost(id: "992001", text: "流畅的回答也需要核对原始资料。", category: "AI")])
    var startupCalls = 0
    AppMock.handler = { request in
        startupCalls += 1
        let messages = try requestBody(request)["messages"] as! [[String: String]]
        let source = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        let content = source["replyText"] == nil ? #"{"reply":"说得再顺，也得翻翻出处。","quote":"需要核对原始资料","caution":"","needs_context":false}"# : #"{"supported":true,"reason":""}"#
        return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    let startup = InteractionModel(root: startupRoot, generator: LocalReplyClient(session: session))
    let startupDeadline = Date().addingTimeInterval(5)
    while (startup.items.first?.state != .ready || startup.preparingReplies) && Date() < startupDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(startupCalls == 2 && startup.items.first?.state == .ready, "async startup loads preferences then prepares old empty replies")
    _ = try startupStore.collect([InteractionPost(id: "992002", text: "流畅的回答也需要核对原始资料。", category: "AI")])
    var offPreferences = try startupStore.loadReplyPreferences(); offPreferences.autoDraft = false; try startupStore.saveReplyPreferences(offPreferences)
    let disabledStartup = InteractionModel(root: startupRoot, generator: LocalReplyClient(session: session))
    let disabledStartupDeadline = Date().addingTimeInterval(5)
    while (disabledStartup.items.count != 2 || !disabledStartup.preferencesLoaded) && Date() < disabledStartupDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(30))
    try require(startupCalls == 2 && disabledStartup.missingReplyCount == 1 && !disabledStartup.preparingReplies, "disabled auto drafting does not prepare on launch")
    disabledStartup.autoDraft = true
    let enabledDeadline = Date().addingTimeInterval(5)
    while disabledStartup.preparingReplies && Date() < enabledDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(startupCalls == 4 && disabledStartup.missingReplyCount == 0, "enabling automatic writing prepares existing backlog")
    _ = try startupStore.collect([InteractionPost(id: "992003", text: "流畅的回答也需要核对原始资料。", category: "AI")])
    disabledStartup.reload()
    disabledStartup.generate(disabledStartup.items.first { $0.id == "992003" }!)
    disabledStartup.saveText("992003", text: "")
    let clearedDeadline = Date().addingTimeInterval(5)
    while disabledStartup.generatingID != nil && Date() < clearedDeadline { try await Task.sleep(for: .milliseconds(20)) }
    let cleared = disabledStartup.items.first { $0.id == "992003" }!
    try require(startupCalls == 6 && cleared.replyText.isEmpty && cleared.candidates.count == 1 && !cleared.needsReplyPreparation, "explicit clearing during generation remains empty with optional candidate")
    try require(disabledStartup.items.allSatisfy { $0.dispatch == nil && $0.record == nil }, "backfill is never publication approval or receipt")
    _ = try startupStore.collect([InteractionPost(id: "992004", text: "流畅的回答也需要核对原始资料。", category: "AI")])
    var timeoutCalls = 0
    AppMock.handler = { _ in timeoutCalls += 1; throw URLError(.timedOut) }
    disabledStartup.prepareMissingReplies()
    let timeoutDeadline = Date().addingTimeInterval(5)
    while disabledStartup.preparingReplies && Date() < timeoutDeadline { try await Task.sleep(for: .milliseconds(20)) }
    disabledStartup.prepareMissingReplies()
    try await Task.sleep(for: .milliseconds(30))
    try require(timeoutCalls == 1 && disabledStartup.items.first { $0.id == "992004" }?.preparationFailure == .needsReview, "timeout is surfaced once without automatic model retries")
    let hotRoot = root.appendingPathComponent("hot-materials")
    let hotInteraction = InteractionModel(root: hotRoot, generator: LocalReplyClient(session: session), synchronousInitialLoad: true)
    let hotCenter = HotMaterialModel(interaction: hotInteraction, writer: HotDraftClient(session: session))
    let now = Date()
    var hotPost = InteractionPost(id: "993001", text: "订阅按钮到处都是，取消订阅却要联系客服，还得填写好几张表格。", username: "author", category: "生活")
    hotPost.discovery = ReplyDiscoveryEvidence(observedAt: now, publishedAt: now, postURL: "https://x.com/author/status/993001", likes: 300, replies: 20)
    _ = try hotCenter.store.importHotMaterials([hotPost], account: "me", preferences: HotMaterialPreferences())
    var hotCalls = 0
    AppMock.handler = { request in
        hotCalls += 1
        try require(request.url?.host == "127.0.0.1", "hot drafts only use local Ollama")
        let body = try requestBody(request), messages = body["messages"] as! [[String: String]]
        let source = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        let content = source["replyText"] == nil ? #"{"text":"买的时候只怕你犹豫，退的时候倒是挺有耐心，一道手续接一道手续。","angle":"取消订阅的反差","quote":"取消订阅却要联系客服","caution":"","needs_context":false}"# : #"{"supported":true,"reason":""}"#
        return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    await hotCenter.tick(); await hotCenter.tick()
    let hotDeadline = Date().addingTimeInterval(5)
    while hotCenter.busy && Date() < hotDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(hotCalls == 2 && hotCenter.items.first?.state == .ready && hotInteraction.items.isEmpty, "automatic adaptation and factual review do not write reply records")
    let hotItem = hotCenter.items[0]
    hotCenter.rewrite(hotItem)
    hotCenter.edit(hotItem, text: "我自己写的这句话，不想让它被改掉。", includeSourceURL: true)
    let hotEditDeadline = Date().addingTimeInterval(5)
    while hotCenter.busy && Date() < hotEditDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(hotCenter.items[0].text == "我自己写的这句话，不想让它被改掉。" && hotCenter.items[0].versions.count == 2, "rewriting produces a candidate and preserves edits")
    hotCenter.setAutomatic(true)
    await hotCenter.waitForPreferences()
    let hotRestart = HotMaterialModel(interaction: hotInteraction, writer: HotDraftClient(session: session))
    await hotRestart.load()
    try require(hotRestart.preferences.automatic && hotRestart.preferences.nextFetchAt! > Date(), "auto cadence persists without immediately browsing on restart")
    hotCenter.setAutomatic(false)
    let hotFlushed = await hotCenter.flush()
    try require(hotCenter.preferences.nextFetchAt == nil && hotFlushed, "automatic discovery can be disabled and edits flush")
    for index in 0..<12 { hotCenter.edit(hotCenter.items[0], text: "快速输入的最终版本\(index)", includeSourceURL: index % 2 == 0) }
    try require(hotCenter.hasPendingEdits && hotCenter.saving, "typing is staged without blocking on durable IO")
    let typingFlushed = await hotCenter.flush()
    try require(typingFlushed && hotCenter.items[0].text == "快速输入的最终版本11" && !hotCenter.items[0].includeSourceURL, "rapid edits coalesce and latest text/link survive flush")
    hotCenter.setAutomatic(true); hotCenter.setAutomatic(false); hotCenter.setAutomatic(true)
    await hotCenter.waitForPreferences()
    let finalHotPreferences = try hotCenter.store.load().hotPreferences
    try require(finalHotPreferences?.automatic == true, "rapid preference saves remain ordered")
    hotCenter.shutdown(); hotRestart.shutdown()
    let originalGenerator = OriginalIdeaModel(interaction: hotInteraction, hot: HotMaterialModel(interaction: hotInteraction), client: OriginalDraftClient(session: session))
    await originalGenerator.load()
    var originalCalls = 0
    AppMock.handler = { request in
        originalCalls += 1
        try require(request.url?.host == "127.0.0.1" && request.url?.port == 11434, "original generation is local only, never X")
        let body = try requestBody(request), messages = body["messages"] as! [[String: String]]
        let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        let content: String
        if let candidates = input["candidates"] {
            content = try originalMockReview(candidates)
        } else { content = #"{"ideas":[{"topic":"吃喝","text":"自助餐的仪式感，就是端着空盘绕了半天，最后又拿了一盘炒饭。"},{"topic":"消费","text":"购物车最擅长的事，是把想省的钱凑成免邮。"}]}"# }
        return (200, try JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    originalGenerator.generate(); originalGenerator.generate()
    let originalDeadline = Date().addingTimeInterval(10)
    while originalGenerator.generating && Date() < originalDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(originalCalls == 2 && originalGenerator.items.count == 2 && !hotInteraction.originalModelBusy, "one batch, independent style review, no double-click generation")
    let originalItem = originalGenerator.items[0]
    for index in 0..<8 { originalGenerator.edit(originalItem, text: "我编辑后的原创短帖，第\(index)版。") }
    let originalFlushed = await originalGenerator.flush()
    try require(originalFlushed && originalGenerator.items[0].text == "我编辑后的原创短帖，第7版。", "latest original edit survives coalesced persistence")
    originalGenerator.generate()
    let duplicateDeadline = Date().addingTimeInterval(10)
    while originalGenerator.generating && Date() < duplicateDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try require(originalGenerator.items.count == 2, "duplicates of initial candidates are not reintroduced after editing")
    let originalRestart = OriginalIdeaModel(interaction: hotInteraction, hot: hotCenter, client: OriginalDraftClient(session: session))
    await originalRestart.load()
    try require(originalRestart.items.count == 2 && !originalRestart.generating, "restart only loads originals and never auto generates or publishes")
    originalGenerator.shutdown(); originalRestart.shutdown()
    print("original app checks passed: batch generation, local-only style review, duplicate click, edits, repeat dedup, restart; no browser or public post")
    print("interaction app-model checks passed: import, edited one-click intent, no approval, restart, local writing and review, no overwrite, duplicate block, failure, pause")
}
@main struct ModelTestMain {
    static func main() {
        let group = DispatchGroup(); group.enter()
        Task { @MainActor in
            do { try await runModelTests() } catch { fputs("app model test failed: \(error)\n", stderr); exit(1) }
            group.leave()
        }
        while group.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    }
}
#endif
