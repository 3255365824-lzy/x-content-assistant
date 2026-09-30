import Foundation
import XContentAssistantCore

func runDiscoveryBridgeTests() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/bridge-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InteractionStore(root: root), bridge = try DiscoveryBridge(store: store)
    let origin = "chrome-extension://" + String(repeating: "a", count: 32)
    func data(_ value: [String: String]) throws -> Data { try JSONEncoder().encode(value) }
    let code = try bridge.connectionCode()
    try check(bridge.handle(method: "POST", path: "/v1/pair", origin: "https://x.com", authorization: "", body: try data(["code": code])).status == 403, "webpage cannot pair")
    let paired = bridge.handle(method: "POST", path: "/v1/pair", origin: origin, authorization: "", body: try data(["code": code]))
    let token = try JSONDecoder().decode([String: String].self, from: paired.data)["token"]!
    try check(paired.status == 200 && token != code, "one-time code exchanges for different local secret")
    try check(bridge.handle(method: "POST", path: "/v1/pair", origin: origin, authorization: "", body: try data(["code": code])).status == 401, "pair code cannot be reused")
    let auth = "Bearer " + token
    try check(bridge.handle(method: "GET", path: "/v1/job", origin: origin, authorization: "wrong", body: Data()).status == 401, "auth required even on loopback")
    try check(bridge.handle(method: "GET", path: "/v1/job", origin: "chrome-extension://" + String(repeating: "b", count: 32), authorization: auth, body: Data()).status == 401, "token also bound to extension ID")
    try check(bridge.handle(method: "GET", path: "/v1/job", origin: origin, authorization: auth, body: Data(repeating: 1, count: 2_000_001)).status == 403, "request bound")
    let job = try bridge.enqueue(policy: ReplyDiscoveryPolicy(), autoDraft: false)
    try rejects("cannot enqueue duplicate active fetch") { _ = try bridge.enqueue(policy: ReplyDiscoveryPolicy(), autoDraft: false) }
    try check(bridge.handle(method: "POST", path: "/v1/claim", origin: origin, authorization: auth, body: try data(["jobID": job.id])).status == 200, "claim request")
    try check(bridge.handle(method: "POST", path: "/v1/claim", origin: origin, authorization: auth, body: try data(["jobID": job.id])).status == 409, "double claim rejected")
    var post = InteractionPost(id: "95100", text: "AI 测试原文：应检查原帖后才准备回复。", username: "large", category: "AI")
    post.discovery = ReplyDiscoveryEvidence(observedAt: Date(), publishedAt: Date(), postURL: "https://x.com/large/status/95100", followers: 100_000, followersSourceURL: "https://x.com/large")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    struct Batch: Encodable { var jobID: String; var account: String; var posts: [InteractionPost] }
    let batch = try encoder.encode(Batch(jobID: job.id, account: "me", posts: [post]))
    try check(bridge.handle(method: "POST", path: "/v1/result", origin: origin, authorization: auth, body: batch).status == 200, "result persisted")
    try check(bridge.handle(method: "POST", path: "/v1/result", origin: origin, authorization: auth, body: batch).status == 409, "result is not applied twice")
    try check(try store.load().items.count == 1 && bridge.snapshot().job?.addedIDs == [post.id], "import and receipt contain exact unseen ID")
    let reopened = try DiscoveryBridge(store: store)
    try check(try reopened.snapshot().job?.state == "complete", "completed result durable")
    let next = try reopened.enqueue(policy: ReplyDiscoveryPolicy(), autoDraft: false)
    try reopened.cancel()
    try check(reopened.handle(method: "POST", path: "/v1/claim", origin: origin, authorization: auth, body: try data(["jobID": next.id])).status == 409, "cancel before claim")
    _ = try reopened.enqueue(policy: ReplyDiscoveryPolicy(), autoDraft: false)
    let restarted = try DiscoveryBridge(store: store)
    try check(try restarted.snapshot().job?.state == "interrupted", "restart never silently resumes reading")
    let secretPath = root.appendingPathComponent(".discovery/connection.json").path
    let permissions = try FileManager.default.attributesOfItem(atPath: secretPath)[.posixPermissions] as! NSNumber
    try check(permissions.intValue == 0o600, "local secret file owner-only")
    var hotPolicy = HotMaterialPreferences(); hotPolicy.minimumLikes = 100
    let materialJob = try restarted.enqueue(policy: hotPolicy.discoveryPolicy, autoDraft: false, hotPreferences: hotPolicy)
    try check(materialJob.isMaterials && materialJob.hotPreferences == hotPolicy, "material job has immutable collection preferences")
    try check(restarted.handle(method: "POST", path: "/v1/claim", origin: origin, authorization: auth, body: try data(["jobID": materialJob.id])).status == 200, "material job uses existing extension claim")
    post.discovery?.likes = 300; post.discovery?.replies = 40
    let materialBatch = try encoder.encode(Batch(jobID: materialJob.id, account: "me", posts: [post]))
    try check(restarted.handle(method: "POST", path: "/v1/result", origin: origin, authorization: auth, body: materialBatch).status == 200, "old extension result protocol can ingest material jobs")
    let both = try store.load()
    try check(both.items.count == 1 && both.items[0].candidates.isEmpty && both.hotMaterials?.count == 1, "same original may be a material without resetting or drafting a reply")
    try check(try restarted.snapshot().job?.message.contains("不是全网热榜") == true, "scope of observed popularity disclosed")
    try check(restarted.handle(method: "POST", path: "/v1/result", origin: origin, authorization: auth, body: materialBatch).status == 409, "completed material batch cannot be replayed")
    print("bridge tests passed: origin, pairing, authentication, bounds, claim, cancellation, durable completion and restart; no browser or public posts")
}

func runLoopbackBridgeSmoke() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/http-" + UUID().uuidString)
    let bridge = try DiscoveryBridge(store: InteractionStore(root: root))
    defer { bridge.stop(); try? FileManager.default.removeItem(at: root) }
    try bridge.start()
    try await Task.sleep(for: .milliseconds(400))
    try check(try bridge.snapshot().error == nil, "loopback listener starts")
    let origin = "chrome-extension://" + String(repeating: "a", count: 32)
    var pair = URLRequest(url: URL(string: "http://127.0.0.1:18796/v1/pair")!)
    pair.httpMethod = "POST"; pair.setValue(origin, forHTTPHeaderField: "Origin")
    pair.setValue("application/json", forHTTPHeaderField: "Content-Type")
    pair.httpBody = try JSONEncoder().encode(["code": bridge.connectionCode()])
    let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    let (data, response) = try await session.data(for: pair)
    try check((response as? HTTPURLResponse)?.statusCode == 200, "pair over real local HTTP transport")
    let token = try JSONDecoder().decode([String: String].self, from: data)["token"]!
    var status = URLRequest(url: URL(string: "http://127.0.0.1:18796/v1/job")!)
    status.setValue(String(repeating: "a", count: 32), forHTTPHeaderField: "X-XContent-Extension")
    status.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let (_, statusResponse) = try await session.data(for: status)
    try check((statusResponse as? HTTPURLResponse)?.statusCode == 200, "GET with extension identity and secret")
    status.setValue("https://x.com", forHTTPHeaderField: "Origin")
    let (_, denied) = try await session.data(for: status)
    try check((denied as? HTTPURLResponse)?.statusCode == 403, "page origin rejected by actual transport")
    session.invalidateAndCancel()
    print("local HTTP bridge smoke passed; no X, tokens not logged")
}
