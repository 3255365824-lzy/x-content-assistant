import Foundation
import Network
import Security

public struct DiscoveryJob: Codable, Sendable, Identifiable {
    public var id = UUID().uuidString
    public var state = "queued"
    public var message = "等待 Edge 扩展读取新帖"
    public var createdAt = Date()
    public var updatedAt = Date()
    public var policy: ReplyDiscoveryPolicy
    public var addedIDs: [String] = []
    public var skipped: [ReplyDiscoverySkip] = []
    public var account: String?
    public var autoDraft: Bool
    public var hotPreferences: HotMaterialPreferences?
    public var isMaterials: Bool { hotPreferences != nil }
    public init(policy: ReplyDiscoveryPolicy, autoDraft: Bool) { self.policy = policy; self.autoDraft = autoDraft }
    public var active: Bool { ["queued", "reading"].contains(state) }
}

public struct DiscoveryBatch: Codable, Sendable {
    public var jobID: String
    public var account: String
    public var posts: [InteractionPost]
}

public struct BridgeSnapshot: Sendable {
    public var connected: Bool
    public var origin: String?
    public var job: DiscoveryJob?
    public var error: String?
}

/// Small authenticated loopback transport. Own serial lock; never holds the interaction lock while browsing.
public final class DiscoveryBridge: @unchecked Sendable {
    public static let port: UInt16 = 18796
    private let store: InteractionStore
    private let root: URL
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "x.discovery.loopback")
    private var listener: NWListener?
    private var listenerError: String?
    private var credential: Credential
    private var job: DiscoveryJob?
    private var pairingCode: String?
    private var pairingUntil = Date.distantPast
    private var failedPairings = 0
    private var lastSeen = Date.distantPast
    private struct Credential: Codable { var token: String; var origin: String? }

    public init(store: InteractionStore) throws {
        self.store = store; root = store.root.appendingPathComponent(".discovery")
        try Self.safe(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let secret = root.appendingPathComponent("connection.json")
        try Self.safe(secret)
        if FileManager.default.fileExists(atPath: secret.path) {
            credential = try Self.read(Credential.self, from: secret, limit: 4096)
            guard credential.token.count == 64, credential.origin == nil || Self.validOrigin(credential.origin!) else { throw InteractionError.invalid("扩展连接配置损坏，请保留文件并检查") }
        } else {
            credential = Credential(token: try Self.random(), origin: nil)
        }
        let file = root.appendingPathComponent("job.json"); try Self.safe(file)
        if FileManager.default.fileExists(atPath: file.path) {
            job = try Self.read(DiscoveryJob.self, from: file, limit: 512_000)
            if job?.active == true { job?.state = "interrupted"; job?.message = "App 上次退出时采集未完成，请重新获取；不会自动继续" }
        }
        try saveCredential(); try saveJob()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw InteractionError.invalid("无法创建本地连接码") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func safe(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw InteractionError.invalid("扩展数据路径不能含符号链接") }
    }
    private static func read<T: Decodable>(_ type: T.Type, from file: URL, limit: Int) throws -> T {
        try safe(file)
        guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= limit else { throw InteractionError.invalid("扩展状态文件过大") }
        let data = try Data(contentsOf: file); guard data.count <= limit else { throw InteractionError.invalid("扩展状态文件过大") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        let file = root.appendingPathComponent(name); try Self.safe(file)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func saveCredential() throws { try write(credential, name: "connection.json") }
    private func saveJob() throws { if let job { try write(job, name: "job.json") } }
    public func connectionCode() throws -> String {
        lock.lock(); defer { lock.unlock() }
        pairingCode = try Self.random(); pairingUntil = Date().addingTimeInterval(300); failedPairings = 0
        return pairingCode!
    }
    public func snapshot() throws -> BridgeSnapshot {
        lock.lock(); defer { lock.unlock() }; try expire()
        return BridgeSnapshot(connected: Date().timeIntervalSince(lastSeen) < 90, origin: credential.origin, job: job, error: listenerError)
    }
    public func enqueue(policy: ReplyDiscoveryPolicy, autoDraft: Bool, hotPreferences: HotMaterialPreferences? = nil) throws -> DiscoveryJob {
        lock.lock(); defer { lock.unlock() }; try expire(); try policy.validate()
        guard credential.origin != nil else { throw InteractionError.invalid("先在「连接扩展」中完成一次配对") }
        guard job?.active != true else { throw InteractionError.invalid("已有采集任务，请等待或取消后重试") }
        if let hotPreferences { try hotPreferences.validate() }
        job = DiscoveryJob(policy: policy, autoDraft: autoDraft); job?.hotPreferences = hotPreferences
        try saveJob(); return job!
    }
    public func cancel() throws {
        lock.lock(); defer { lock.unlock() }
        if job?.active == true { job?.state = "cancelled"; job?.message = "已取消；已在本地的草稿保留"; job?.updatedAt = Date(); try saveJob() }
    }
    private func expire() throws {
        if job?.active == true, Date().timeIntervalSince(job!.createdAt) > 360 {
            job?.state = "failed"; job?.message = "采集超时；请确认 Edge 已打开、X 已登录、扩展可用后重新获取"; try saveJob()
        }
    }
    private static func validOrigin(_ value: String) -> Bool { value.range(of: "^chrome-extension://[a-p]{32}$", options: .regularExpression) != nil }
    private static func sameSecret(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8); guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    public struct Response: Sendable { public var status: Int; public var data: Data }
    private func response<T: Encodable>(_ value: T, status: Int = 200) throws -> Response {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return Response(status: status, data: try encoder.encode(value))
    }
    /// Testable without listening or accessing a real browser. Only the paired extension may submit.
    public func handle(method: String, path: String, origin: String, authorization: String, body: Data) -> Response {
        lock.lock(); defer { lock.unlock() }
        do {
            guard Self.validOrigin(origin), body.count <= 2_000_000 else { return try response(["error": "请求来源或大小不合法"], status: 403) }
            if method == "OPTIONS" { return try response(["ok": true]) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if method == "POST", path == "/v1/pair" {
                let data = try decoder.decode([String: String].self, from: body)
                guard failedPairings < 5, Date() < pairingUntil, let code = pairingCode,
                      Self.sameSecret(data["code"] ?? "", code) else {
                    failedPairings += 1; return try response(["error": "连接码错误、过期或尝试过多；在 App 重新复制连接码"], status: 401)
                }
                // Rotate on pairing; any previous extension immediately loses access.
                credential = Credential(token: try Self.random(), origin: origin); try saveCredential()
                pairingCode = nil; lastSeen = Date()
                return try response(["token": credential.token])
            }
            guard credential.origin == origin, Self.sameSecret(authorization, "Bearer " + credential.token) else { return try response(["error": "扩展未连接，请重新配对"], status: 401) }
            lastSeen = Date(); try expire()
            if method == "GET", path == "/v1/job" {
                struct Snapshot: Encodable { var job: DiscoveryJob? }
                return try response(Snapshot(job: job))
            }
            guard method == "POST" else { return try response(["error": "不支持的请求"], status: 404) }
            if path == "/v1/result" {
                let batch = try decoder.decode(DiscoveryBatch.self, from: body)
                guard var active = job, active.id == batch.jobID, active.state == "reading" else { return try response(["error": "任务已取消、完成或失效，未写入结果"], status: 409) }
                let result: ReplyDiscoverySelection
                if let preferences = active.hotPreferences {
                    result = try store.importHotMaterials(batch.posts, account: batch.account, preferences: preferences)
                } else { result = try store.importDiscovered(batch.posts, account: batch.account, policy: active.policy) }
                active.addedIDs = result.posts.map(\.id); active.skipped = result.skipped; active.account = batch.account
                active.state = "complete"; active.message = "新增 \(result.posts.count) 条，跳过 \(result.skipped.count) 条；粉丝数来自公开主页，可在详情核对"
                if active.isMaterials { active.message = "收集 \(result.posts.count) 条近期高互动素材，跳过 \(result.skipped.count) 条；仅限本轮可见关注流，不是全网热榜。" }
                active.updatedAt = Date(); job = active; try saveJob()
                return try response(["saved": true])
            }
            let data = try decoder.decode([String: String].self, from: body)
            guard data["jobID"] == job?.id, job?.active == true else { return try response(["error": "任务已失效"], status: 409) }
            switch path {
            case "/v1/claim":
                guard job?.state == "queued" else { return try response(["error": "任务已被领取"], status: 409) }
                job?.state = "reading"; job?.message = "正在读取 Edge 页面…"
            case "/v1/progress":
                guard job?.state == "reading" else { return try response(["error": "任务尚未领取"], status: 409) }
                job?.message = String((data["message"] ?? "读取中").prefix(200))
            case "/v1/fail":
                job?.state = "failed"
                let reason = data["message"] ?? "读取失败，请重试"
                job?.message = reason.localizedCaseInsensitiveContains("No current window") ? "Edge 没有可用窗口，请先打开 Edge 窗口，再点获取；未收集或发送任何内容。" : String(reason.prefix(500))
            default: return try response(["error": "不存在的接口"], status: 404)
            }
            job?.updatedAt = Date(); try saveJob(); return try response(["ok": true])
        } catch { return (try? response(["error": "本地处理失败：" + String(error.localizedDescription.prefix(350))], status: 400)) ?? Response(status: 500, data: Data()) }
    }
    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if case .failed = state { self.listenerError = "本地扩展端口 18796 无法启动；请关闭另一份素材助手或检查端口占用" }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        listener.start(queue: queue); self.listener = listener
    }
    public func stop() { listener?.cancel(); listener = nil; try? cancel() }
    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { connection.cancel() }
        read(connection, bytes: Data())
    }
    private func read(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = bytes; if let data { bytes.append(data) }
            guard error == nil, bytes.count <= 2_016_384 else { connection.cancel(); return }
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || bytes.count > 16_384 { connection.cancel() } else { self.read(connection, bytes: bytes) }; return
            }
            guard boundary.lowerBound <= 16_384, let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { connection.cancel(); return }
            let lines = header.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
            guard first.count == 3 else { connection.cancel(); return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, headers[parts[0].lowercased()] == nil else { connection.cancel(); return }
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            guard headers["host"] == "127.0.0.1:\(Self.port)", headers["transfer-encoding"] == nil,
                  let length = Int(headers["content-length"] ?? "0"), (0...2_000_000).contains(length) else { connection.cancel(); return }
            let body = Data(bytes[boundary.upperBound...])
            guard body.count >= length else { if complete { connection.cancel() } else { self.read(connection, bytes: bytes) }; return }
            guard body.count == length else { connection.cancel(); return }
            // Some Chromium extension GETs omit Origin. Authentication is still the secret,
            // not this public identifier; ordinary web origins are never replaced.
            let origin = headers["origin"] ?? headers["x-xcontent-extension"].map { "chrome-extension://" + $0 } ?? ""
            let result = self.handle(method: String(first[0]), path: String(first[1]), origin: origin, authorization: headers["authorization"] ?? "", body: body)
            let cors = Self.validOrigin(origin) ? "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type, X-XContent-Extension\r\n" : ""
            let response = "HTTP/1.1 \(result.status) Response\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\n\(cors)Content-Length: \(result.data.count)\r\n\r\n"
            connection.send(content: Data(response.utf8) + result.data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
