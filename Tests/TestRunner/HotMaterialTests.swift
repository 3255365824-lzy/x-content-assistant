import Foundation
import XContentAssistantCore

func hotFixture(_ id: String, likes: Int? = 200, replies: Int? = 30, age: Double = 1, author: String = "author", now: Date = Date()) -> InteractionPost {
    var post = InteractionPost(id: id, text: "订阅按钮到处都是，取消订阅却要联系客服，还得填写好几张表格。", username: author, category: "生活")
    post.discovery = ReplyDiscoveryEvidence(observedAt: now, publishedAt: now.addingTimeInterval(-age * 3600), postURL: "https://x.com/\(author)/status/\(id)", likes: likes, replies: replies)
    return post
}
func runHotMaterialTests() throws {
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/hot-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InteractionStore(root: root)
    var preferences = HotMaterialPreferences()
    let unknown = hotFixture("97101", likes: nil, replies: nil, now: now)
    var popularAuthor = hotFixture("97102", likes: 2, replies: 1, now: now)
    popularAuthor.discovery?.followers = 1_000_000; popularAuthor.discovery?.followersSourceURL = "https://x.com/author"
    let hot = hotFixture("97103", now: now), older = hotFixture("97104", age: 50, now: now)
    var media = hotFixture("97105", now: now); media.text = "听说这个视频非常刺激，是真的吗？"
    var ad = hotFixture("97106", now: now); ad.discovery?.isPromoted = true
    let own = hotFixture("97107", author: "me", now: now)
    let selected = try store.importHotMaterials([unknown, popularAuthor, hot, older, media, ad, own], account: "me", preferences: preferences, now: now)
    try check(selected.posts.map(\.id) == [hot.id], "only fresh measured engagement, not follower counts or missing media")
    try check(try store.load().items.isEmpty && store.load().hotMaterials?.count == 1, "material ingestion does not pollute reply queue")
    let version = HotDraftVersion(text: "买的时候只怕你犹豫，退的时候倒是挺有耐心，一道手续接一道手续。", angle: "取消订阅的反差", quote: "取消订阅却要联系客服", caution: "")
    try HotMaterialRules.validateAdaptation(version, source: hot.text)
    try store.addHotVersion(hot.id, version: version, expectedRevision: 0, expectedSource: hot.text)
    try check(try store.load().hotMaterials?.first?.state == .ready, "generated adaptation becomes local ready draft")
    try store.editHot(hot.id, text: "我自己写的，不要替换它。", includeSourceURL: true)
    try store.addHotVersion(hot.id, version: version, expectedRevision: 0, expectedSource: hot.text)
    try check(try store.load().hotMaterials?.first?.text == "我自己写的，不要替换它。", "late generation cannot replace manual text")
    try check(try store.importHotMaterials([hot], account: "me", preferences: preferences, now: now).posts.isEmpty, "repeat collection keeps exact edited source and draft")
    let revision = try store.load().hotMaterials!.first!.revision
    try store.editHot(hot.id, text: "", includeSourceURL: false)
    try store.addHotVersion(hot.id, version: version, expectedRevision: revision, expectedSource: hot.text)
    try check(try store.load().hotMaterials?.first?.text.isEmpty == true && store.load().hotMaterials?.first?.needsAdaptation == false, "explicit clearing survives generation and restart")
    try store.editHot(hot.id, text: version.text, includeSourceURL: true)
    let snapshot = try store.load().hotMaterials!.first!
    let url = try HotMaterialRules.intentURL(text: snapshot.finalText)
    try check(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == snapshot.finalText, "manual post intent contains edited text and selected source link")
    try store.handoffHot(snapshot)
    try rejects("duplicate hot handoff") { try store.handoffHot(snapshot) }
    try check(try store.load().hotMaterials?.first?.state == .handedOff, "opening browser is handed off, never published")
    var copied = version; copied.text = hot.text
    try rejects("copied source is not adaptation") { try HotMaterialRules.validateAdaptation(copied, source: hot.text) }
    var unsupported = version; unsupported.text = "99% 的服务都喜欢这么做，这不是用户的问题。"
    try rejects("unsupported number") { try HotMaterialRules.validateAdaptation(unsupported, source: hot.text) }
    unsupported.text = "你应该服用药物，这样就不会再被吓到。"
    try rejects("personal medical advice") { try HotMaterialRules.validateAdaptation(unsupported, source: hot.text) }
    preferences.categories = ["AI"]
    try check(try HotMaterialRules.select([hot], existingIDs: [], account: "me", preferences: preferences, now: now).posts.isEmpty, "interest filters respected")
    preferences.categories = []
    let ranked = try HotMaterialRules.select([hotFixture("97201", likes: 500, replies: 0, age: 30, author: "old", now: now), hotFixture("97202", likes: 300, replies: 50, age: 1, author: "new", now: now)], existingIDs: [], account: "me", preferences: preferences, now: now)
    try check(ranked.posts.first?.id == "97202", "heat ranking incorporates freshness")
    try check(!preferences.isDue(now: now), "automatic browsing is off until user enables")
    preferences.automatic = true; preferences.nextFetchAt = now.addingTimeInterval(3600)
    try check(!preferences.isDue(now: now) && preferences.isDue(now: now.addingTimeInterval(3601)), "bounded automatic interval")
    try store.saveHotPreferences(preferences)
    try check(try InteractionStore(root: root).load().hotPreferences == preferences, "schedule and voice preferences survive restart")
    print("hot material tests passed: engagement, age, unknown metrics, interests, dedup, revision protection, provenance, similarity, safe manual handoff and interval")
}

func runHotMaterialNetworkTests() async throws {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    var calls = 0, onlyLocal = true
    MockURLProtocol.handler = { request in
        calls += 1; onlyLocal = onlyLocal && request.url?.host == "127.0.0.1"
        let content = calls == 1 ? #"{"text":"买的时候只怕你犹豫，退的时候倒是挺有耐心，一道手续接一道手续。","angle":"取消订阅的反差","quote":"取消订阅却要联系客服","caution":"","needs_context":false}"# : #"{"supported":true,"reason":""}"#
        return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": content]]))
    }
    let version = try await HotDraftClient(session: session).adapt(hotFixture("97301"), preferences: HotMaterialPreferences())
    try check(calls == 2 && onlyLocal && version.angle == "取消订阅的反差", "adaptation plus independent review are local only")
    calls = 0
    MockURLProtocol.handler = { _ in calls += 1; return (200, try! JSONSerialization.data(withJSONObject: ["message": ["content": #"{"text":"","angle":"","quote":"","caution":"原文缺少依据","needs_context":true}"#]])) }
    do { _ = try await HotDraftClient(session: session).adapt(hotFixture("97301"), preferences: HotMaterialPreferences()); throw CheckFailure(message: "insufficient source accepted") } catch is InteractionError { }
    try check(calls == 1, "failure is not retried to force a draft")
    print("hot material model mocks passed; no real X request")
}
