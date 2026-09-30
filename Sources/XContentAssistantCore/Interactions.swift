import Foundation
import Darwin

public enum InteractionError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum ReplyState: String, Codable, CaseIterable, Sendable {
    case unread, ready, needsContext, skipped, opened, recorded, approved, sending, uncertain, sent
    public var label: String {
        switch self {
        case .unread: "待写回复"
        case .ready: "待发送"
        case .needsContext: "需补充上下文"
        case .skipped: "已跳过"
        case .opened: "已处理"
        case .recorded: "人工确认已回复"
        case .approved: "已确认 · 等待执行"
        case .sending: "正在网页核对"
        case .uncertain: "发送结果待核对"
        case .sent: "网页已核验回复"
        }
    }
}

/// Handed off is a queue decision, not evidence that anything was published.
public enum ReplyListFilter: String, CaseIterable, Sendable {
    case pending = "待处理", readyToSend = "待发送", handled = "已处理", needsReview = "待核对", replied = "已回复", skipped = "已跳过", all = "全部"
    public func includes(_ state: ReplyState) -> Bool {
        switch self {
        case .pending: ![.opened, .recorded, .sent, .skipped].contains(state)
        case .readyToSend: state == .ready
        case .handled: [.opened, .recorded, .sent].contains(state)
        case .needsReview: state == .uncertain
        case .replied: [.recorded, .sent].contains(state)
        case .skipped: state == .skipped
        case .all: true
        }
    }
}

public struct InteractionPost: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var username: String
    public var authorID: String?
    public var createdAt: String?
    public var category: String
    public var origin: String
    public var sourceAccountID: String?
    /// Optional and backward-compatible; absent metrics are unknown, never zero followers.
    public var discovery: ReplyDiscoveryEvidence?
    public var url: URL { URL(string: "https://x.com/i/status/\(id)")! }
    public init(id: String, text: String, username: String = "作者未提供", authorID: String? = nil, createdAt: String? = nil, category: String = "其他", origin: String = "手动粘贴", sourceAccountID: String? = nil) {
        self.id = id; self.text = text; self.username = username; self.authorID = authorID; self.createdAt = createdAt; self.category = category; self.origin = origin; self.sourceAccountID = sourceAccountID
    }
}

public struct ReplyCandidate: Codable, Identifiable, Equatable, Sendable {
    public var id: String = UUID().uuidString
    public var text: String
    public var quote: String
    public var caveat: String
    public var createdAt: Date = Date()
    public init(text: String, quote: String, caveat: String) { self.text = text; self.quote = quote; self.caveat = caveat }
}

/// Narrow input for browser-observed drafts. Never accepts approvals or receipts.
public struct PreparedReply: Codable, Sendable {
    public var post: InteractionPost
    public var replyText: String
    public var quote: String
    public var caveat: String
    public var observedAt: Date
    public init(post: InteractionPost, replyText: String, quote: String, caveat: String, observedAt: Date = Date()) {
        self.post = post; self.replyText = replyText; self.quote = quote; self.caveat = caveat; self.observedAt = observedAt
    }
}

public struct PreparedReplyImport: Codable, Sendable {
    public var addedIDs: [String]
    public var skippedIDs: [String]
    public var remainingCapacity: Int
}

public struct ReplyReview: Codable, Equatable, Sendable {
    public var text: String
    public var reviewedAt: Date
    public var sourceText: String
}

public struct ReplyRecord: Codable, Equatable, Sendable {
    public var url: String
    public var finalText: String
    public var recordedAt: Date
    public var kind = "manual_confirmed"
}

public enum ReplyPreparationFailure: String, Codable, Sendable {
    case echoRetryExhausted, needsReview
}

public struct InteractionItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String { post.id }
    public var post: InteractionPost
    public var state: ReplyState = .unread
    public var replyText = ""
    public var candidates: [ReplyCandidate] = []
    public var note = ""
    public var review: ReplyReview?
    public var record: ReplyRecord?
    public var dispatch: ReplyDispatch?
    public var dispatchHistory: [ReplyDispatch]?
    // Optional so existing records load unchanged. Explicit clearing is also an edit.
    public var editRevision: Int?
    public var preparationFailure: ReplyPreparationFailure?
    public var updatedAt = Date()
    public var editable: Bool { [.unread, .ready, .needsContext, .skipped].contains(state) }
    public var isRecoverableEcho: Bool {
        state == .needsContext && note == ReplyWritingRules.legacyEchoMessage && preparationFailure == nil
    }
    public var needsReplyPreparation: Bool {
        replyText.isEmpty && candidates.isEmpty && (editRevision ?? 0) == 0 &&
        record == nil && review == nil && dispatch == nil && preparationFailure == nil &&
        (state == .unread || isRecoverableEcho)
    }
    public init(post: InteractionPost) { self.post = post }
}

public struct InteractionDatabase: Codable, Sendable {
    public var schema = 1
    public var items: [InteractionItem] = []
    public var lastFetchedAt: Date?
    public var lastAccountID: String?
    public var executor: ReplyExecutorStatus?
    public var manualRepliesOnly: Bool?
    public var replyPreferences: ReplyPreferences?
    public var hotMaterials: [HotMaterial]?
    public var hotPreferences: HotMaterialPreferences?
    public var originalIdeas: [OriginalIdea]?
    public var originalPreferences: OriginalPreferences?
    public init() {}
}

public enum ManualReplyRules {
    public static func intentURL(postID: String, text: String) throws -> URL {
        guard InteractionRules.validID(postID) else { throw InteractionError.invalid("原帖 ID 无效") }
        try InteractionRules.validateReply(text)
        var url = URLComponents()
        url.scheme = "https"; url.host = "x.com"; url.path = "/intent/tweet"
        url.queryItems = [URLQueryItem(name: "in_reply_to", value: postID), URLQueryItem(name: "text", value: text)]
        // Some web query decoders treat a literal plus as a space.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = url.url else { throw InteractionError.invalid("无法创建回复链接") }
        return result
    }
}

public enum InteractionRules {
    public static let categories = ["医学", "AI", "科技", "职场", "生活", "趣味", "观点", "其他"]
    public static func validID(_ id: String) -> Bool { id.range(of: "^[1-9][0-9]{0,24}$", options: .regularExpression) != nil }
    public static func postID(from value: String) throws -> String {
        guard let url = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { throw InteractionError.invalid("请粘贴 https://x.com/作者/status/数字 形式的原帖链接") }
        let path = url.path.split(separator: "/").map(String.init)
        let id: String?
        if path.count == 3 && path[1] == "status" { id = path[2] }
        else if path.count == 4 && path[0] == "i" && path[1] == "web" && path[2] == "status" { id = path[3] }
        else { id = nil }
        guard let id, validID(id) else { throw InteractionError.invalid("链接必须指向一条 X 帖子，不接受主页或短链接") }
        return id
    }
    public static func category(_ text: String) -> String {
        if text.range(of: "医学|健康|睡眠|运动|药物|临床|患者|疾病|医疗|疫苗|癌症|\\b(medical|health|clinical|sleep|vaccine|medicine)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return "医学" }
        if text.range(of: "人工智能|大模型|模型|机器学习|提示词|幻觉|\\b(ai|llm|gpt|openai|claude|gemini|qwen|ollama|chatgpt|opus|codex|muse)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return "AI" }
        if text.range(of: "数码|芯片|电脑|手机|软件|网络|路由|\\b(wifi|vpn|iphone|mac)\\b", options: [.regularExpression, .caseInsensitive]) != nil { return "科技" }
        if text.range(of: "职场|上班|下班|工资|公司|同事|加班|老板|工作", options: .regularExpression) != nil { return "职场" }
        if text.range(of: "吸血鬼|笑话|段子|搞笑|哈哈|😂|🤣", options: .regularExpression) != nil { return "趣味" }
        if text.range(of: "吃|饭|面|旅行|现金|红包|生活|周末|咖啡|睡觉", options: .regularExpression) != nil { return "生活" }
        if text.range(of: "觉得|认为|怎么看|道理|规律|胜负|观点", options: .regularExpression) != nil { return "观点" }
        return "其他"
    }
    public static func validateSource(_ post: InteractionPost) throws {
        guard validID(post.id), (8...12000).contains(post.text.count), post.username.count <= 100 else { throw InteractionError.invalid("原帖需有 8–12000 字的可读正文和有效帖子 ID；图片帖请补充图片文字") }
    }
    public static func validateReply(_ text: String) throws {
        let value = XTextRules.validate(postText: text, sourceURL: nil, includeSourceURL: false)
        guard value.valid else { throw InteractionError.invalid(value.message) }
    }
    public static func validateGenerated(text: String, quote: String, source: String) throws {
        try validateReply(text)
        guard quote.count >= 6, source.contains(quote) else { throw InteractionError.invalid("模型没有提供原帖中的连续原文依据，请补充上下文或自己写回复") }
        guard text.range(of: "https?://|@|#[^ ]+", options: .regularExpression) == nil else { throw InteractionError.invalid("回复候选含额外链接、提及或推广标签，未采纳") }
        let regex = try NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)*(?:%|％)?")
        func numbers(_ value: String) -> Set<String> { Set(regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { Range($0.range, in: value).map { String(value[$0]) } }) }
        guard numbers(text).isSubset(of: numbers(source)) else { throw InteractionError.invalid("回复出现原帖没有的数字，未采纳") }
        guard text.range(of: "停药|加药|减药|加量|减量|你患有|你得了|你应该服用|保证治愈|百分百|绝对安全|包治", options: .regularExpression) == nil else { throw InteractionError.invalid("回复涉及个人诊疗或绝对化断言，未采纳") }
    }
}

/// Short atomic transactions only; never hold this lock across a network/model request.
public final class InteractionStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    public init(root: URL) { self.root = root }
    private func checkPath(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            // Foundation attributesOfItem also enumerates xattrs on macOS. That can
            // block inside getxattr during app launch. lstat checks only link metadata.
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                if (metadata.st_mode & S_IFMT) == S_IFLNK { throw InteractionError.invalid("互动数据目录不允许符号链接") }
            } else if errno != ENOENT { throw InteractionError.invalid("无法安全检查互动数据路径") }
            current.deleteLastPathComponent()
        }
    }
    func transaction<T>(write: Bool, _ body: (inout InteractionDatabase) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try checkPath(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw InteractionError.invalid("无法锁定互动数据目录") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw InteractionError.invalid("互动数据锁定失败") }
        let path = root.appendingPathComponent("interactions.json"); try checkPath(path)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var db = InteractionDatabase()
        if FileManager.default.fileExists(atPath: path.path) {
            let size = (try path.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= 16_000_000 else { throw InteractionError.invalid("互动记录过大，请先备份检查") }
            db = try decoder.decode(InteractionDatabase.self, from: Data(contentsOf: path))
            guard db.schema == 1 else { throw InteractionError.invalid("互动数据版本不兼容，未修改原文件") }
            guard db.items.count <= 1000, Set(db.items.map(\.id)).count == db.items.count else { throw InteractionError.invalid("互动数据存在重复或超量条目，未修改原文件") }
            for item in db.items { try InteractionRules.validateSource(item.post) }
            if let hot = db.hotMaterials {
                guard hot.count <= 500, Set(hot.map(\.id)).count == hot.count else { throw InteractionError.invalid("热门素材记录重复或超量，未修改原文件") }
                for item in hot { try HotMaterialRules.validateStored(item) }
            }
            if let preferences = db.hotPreferences { try preferences.validate() }
            if let ideas = db.originalIdeas {
                guard ideas.count <= 1000, Set(ideas.map(\.id)).count == ideas.count else { throw InteractionError.invalid("自拟灵感重复或超量，未修改原文件。") }
                for idea in ideas { try OriginalRules.validateStored(idea) }
            }
            if let preferences = db.originalPreferences { try preferences.validate() }
        }
        let result = try body(&db)
        if write {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(db)
            guard data.count <= 16_000_000 else { throw InteractionError.invalid("互动记录已达本地容量上限，未覆盖旧记录") }
            try data.write(to: path, options: .atomic)
            let saved = open(path.path, O_RDONLY | O_NOFOLLOW)
            guard saved >= 0 else { throw InteractionError.invalid("互动记录持久化检查失败，请重新读取，不要重复发送") }
            let syncResult = fsync(saved); close(saved)
            guard syncResult == 0 else { throw InteractionError.invalid("互动记录同步失败，请重新读取，不要重复发送") }
            let directory = open(root.path, O_RDONLY | O_NOFOLLOW)
            guard directory >= 0 else { throw InteractionError.invalid("互动目录同步失败") }
            let directorySync = fsync(directory); close(directory)
            guard directorySync == 0 else { throw InteractionError.invalid("互动目录同步失败，请重新读取") }
        }
        return result
    }
    public func load() throws -> InteractionDatabase { try transaction(write: false) { $0 } }
    /// Read afresh for each generation; updates never require resetting interaction data.
    public func loadReplyStyle() throws -> ReplyStyleProfile {
        let path = root.appendingPathComponent("reply-style.json")
        try checkPath(path)
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            if errno == ENOENT { return ReplyStyleProfile() }
            throw InteractionError.invalid("无法读取风格参考，可关闭此选项后重试")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= 65_536 else {
            throw InteractionError.invalid("风格参考必须是不超过 64 KB 的普通 JSON 文件")
        }
        let data = try Data(contentsOf: path)
        guard data.count <= 65_536 else { throw InteractionError.invalid("风格参考过大") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(ReplyStyleProfile.self, from: data)
        try profile.validate()
        return profile
    }
    /// One-time migration of the candidate copy, never the old App's store.
    public func loadForManualReplies(now: Date = Date()) throws -> InteractionDatabase {
        let previous = try load()
        guard previous.manualRepliesOnly != true else { return previous }
        return try transaction(write: true) { db in
            guard db.manualRepliesOnly != true else { return db }
            db.manualRepliesOnly = true; db.executor = nil
            for index in db.items.indices {
                guard var job = db.items[index].dispatch, db.items[index].record == nil else { continue }
                switch job.state {
                case .queued:
                    job.state = .cancelled; job.reason = "已切换手动发送，旧的等待代发批准已撤销；文案保留。"
                    db.items[index].state = .ready; db.items[index].review = nil
                case .preparing, .clickCommitted:
                    job.state = .uncertain; job.reason = "旧流程可能已操作网页，请先人工核对是否发出；新版不会继续执行或重发。"
                    db.items[index].state = .uncertain
                default: continue
                }
                job.updatedAt = now; db.items[index].dispatch = job
            }
            return db
        }
    }
    public func importPrepared(_ replies: [PreparedReply], now: Date = Date()) throws -> PreparedReplyImport {
        guard (1...50).contains(replies.count) else { throw InteractionError.invalid("每批需包含 1–50 条待审核候选") }
        // Validate the whole batch before starting a write. Evidence is a quote, not fact approval.
        for reply in replies {
            try InteractionRules.validateSource(reply.post)
            guard ["医学", "AI"].contains(reply.post.category),
                  reply.post.username.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil,
                  reply.caveat.count <= 1000,
                  (-300...86400).contains(now.timeIntervalSince(reply.observedAt)) else {
                throw InteractionError.invalid("候选需有真实作者、医学/AI 分类、近期网页观察时间及简短核对说明")
            }
            try InteractionRules.validateGenerated(text: reply.replyText, quote: reply.quote, source: reply.post.text)
        }
        return try transaction(write: true) { db in
            var added: [String] = [], skipped: [String] = []
            var ids = Set(db.items.map(\.id))
            var texts = Set(db.items.map { $0.replyText.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            for reply in replies {
                let text = reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ids.contains(reply.post.id), !texts.contains(text) else { skipped.append(reply.post.id); continue }
                guard db.items.count < 1000 else { throw InteractionError.invalid("互动箱已达 1000 条上限；未覆盖或删除旧记录，请先整理") }
                var post = reply.post
                post.origin = "Edge 网页观察 · 定时准备候选"
                post.sourceAccountID = nil
                var item = InteractionItem(post: post)
                item.replyText = text; item.state = .ready; item.updatedAt = now
                item.candidates = [ReplyCandidate(text: text, quote: reply.quote, caveat: reply.caveat)]
                item.note = "仅待审核，未批准发送。" + reply.caveat
                // Fresh value: no review, dispatch, dispatchHistory or publication record can be imported.
                db.items.insert(item, at: 0)
                ids.insert(post.id); texts.insert(text); added.append(post.id)
            }
            if !added.isEmpty { db.lastFetchedAt = now }
            return PreparedReplyImport(addedIDs: added, skippedIDs: skipped, remainingCapacity: 1000 - db.items.count)
        }
    }
    @discardableResult public func collect(_ posts: [InteractionPost], accountID: String? = nil, fetchedAt: Date? = nil) throws -> Int {
        try transaction(write: true) { db in
            var added = 0
            for post in posts {
                try InteractionRules.validateSource(post)
                if let index = db.items.firstIndex(where: { $0.id == post.id }) {
                    if db.items[index].post.text != post.text && db.items[index].editable {
                        db.items[index].post = post; db.items[index].state = .needsContext; db.items[index].replyText = ""
                        db.items[index].note = "原文发生变化，旧候选仅供历史参考，请重新生成或编辑。"
                    }
                    continue
                }
                guard db.items.count < 1000 else { throw InteractionError.invalid("互动箱已达 1000 条上限，先备份整理后再读取") }
                db.items.insert(InteractionItem(post: post), at: 0); added += 1
            }
            if let fetchedAt { db.lastFetchedAt = fetchedAt; db.lastAccountID = accountID }
            return added
        }
    }
    @discardableResult public func update(_ id: String, _ body: (inout InteractionItem) throws -> Void) throws -> InteractionItem {
        try transaction(write: true) { db in
            guard let index = db.items.firstIndex(where: { $0.id == id }) else { throw InteractionError.invalid("互动条目不存在") }
            try body(&db.items[index]); db.items[index].updatedAt = Date(); return db.items[index]
        }
    }
    public func edit(_ id: String, text: String) throws {
        _ = try update(id) { item in
            guard item.editable, text.count <= 4000 else { throw InteractionError.invalid("请先核对是否已发送；已登记的回复不能改写") }
            item.replyText = text; item.state = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unread : .ready
            item.editRevision = (item.editRevision ?? 0) + 1
        }
    }
    public func addCandidate(_ id: String, candidate: ReplyCandidate, sourceText: String, expectedEditRevision: Int? = nil) throws {
        _ = try update(id) { item in
            guard item.editable, item.state != .skipped, item.post.text == sourceText else { throw InteractionError.invalid("原帖或回复状态已改变，未覆盖编辑") }
            try InteractionRules.validateGenerated(text: candidate.text, quote: candidate.quote, source: sourceText)
            item.candidates.append(candidate); if item.candidates.count > 20 { item.candidates.removeFirst() }
            // New candidates never replace current editing.
            if expectedEditRevision == nil || expectedEditRevision == (item.editRevision ?? 0) {
                if item.replyText.isEmpty { item.replyText = candidate.text; item.state = .ready }
                item.note = candidate.caveat; item.preparationFailure = nil
            }
        }
    }
    public func markOpened(_ id: String, expectedText: String, expectedSource: String? = nil) throws -> InteractionItem {
        try update(id) { item in
            guard item.editable, item.state != .skipped, item.replyText == expectedText else { throw InteractionError.invalid("回复已变化或已打开，请重新审核；不要重复发送") }
            guard expectedSource == nil || item.post.text == expectedSource else { throw InteractionError.invalid("审核期间原帖发生变化，请重新核对") }
            try InteractionRules.validateReply(expectedText)
            item.review = ReplyReview(text: expectedText, reviewedAt: Date(), sourceText: item.post.text); item.state = .opened
        }
    }
    public func resolveNotSent(_ id: String) throws {
        _ = try update(id) { item in
            guard item.state == .opened else { throw InteractionError.invalid("只有已交接到 X 的条目可移回待处理；不确定的旧发送记录仍需单独核对") }
            item.state = .ready; item.review = nil
        }
    }
    public func recordManual(_ id: String, url: String, finalText: String) throws {
        let replyID = try InteractionRules.postID(from: url)
        guard replyID != id else { throw InteractionError.invalid("请填你发出的回复链接，不是原帖链接") }
        try InteractionRules.validateReply(finalText)
        _ = try update(id) { item in
            guard item.state == .opened || item.state == .uncertain else { throw InteractionError.invalid("请先前往 X 回复并核对结果；已登记条目不能重复登记") }
            if let dispatch = item.dispatch {
                item.dispatchHistory = (item.dispatchHistory ?? []) + [dispatch]; item.dispatch = nil
            }
            item.record = ReplyRecord(url: "https://x.com/i/status/\(replyID)", finalText: finalText, recordedAt: Date()); item.state = .recorded
        }
    }
}

public struct LocalReplyResponse: Codable, Sendable {
    public var reply: String
    public var quote: String
    public var caution: String
    public var needs_context: Bool
}

public final class LocalReplyClient: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func generate(post: InteractionPost, tone: String = ReplyWritingRules.defaultTone, currentReply: String = "", recentReplies: [String] = [], styleNotes: [String] = [], recoveringEcho: Bool = false) async throws -> ReplyCandidate {
        try InteractionRules.validateSource(post)
        try ReplyWritingRules.validateTextContext(post)
        let system = try ReplyWritingRules.systemPrompt(tone: tone)
        var source = ReplyWritingRules.sourcePayload(post: post, tone: tone, currentReply: currentReply, recentReplies: recentReplies, styleNotes: styleNotes)
        var isRepair = recoveringEcho
        var result: LocalReplyResponse
        while true {
            try Task.checkCancellation()
            result = try JSONDecoder().decode(LocalReplyResponse.self, from: await completion(system: system + (isRepair ? "\n" + ReplyWritingRules.echoRepairPrompt : ""), input: source, temperature: 0.65, limit: 500))
            guard !result.needs_context else { throw InteractionError.invalid("需要补充上下文：\(result.caution.prefix(300))") }
            try InteractionRules.validateGenerated(text: result.reply, quote: result.quote, source: post.text)
            do { try ReplyWritingRules.validateNotEcho(result.reply, source: post.text); break }
            catch ReplyWritingError.echo {
                guard !isRepair else { throw ReplyWritingError.echoRetryExhausted }
                isRepair = true; source["echoedReply"] = String(result.reply.prefix(500))
            }
        }
        try Task.checkCancellation()
        struct Review: Decodable { var supported: Bool; var reason: String }
        let review = try JSONDecoder().decode(Review.self, from: await completion(system: ReplyWritingRules.reviewPrompt, input: ["sourceText": post.text, "replyText": result.reply], temperature: 0, limit: 220))
        guard review.supported else { throw InteractionError.invalid("这版补了原帖没有确认的意思，未放入候选：\(review.reason.prefix(200))。可换个说法或自己改写。") }
        return ReplyCandidate(text: result.reply, quote: result.quote, caveat: result.caution)
    }

    func completion(system: String, input: [String: String], temperature: Double, limit: Int) async throws -> Data {
        let source = try JSONSerialization.data(withJSONObject: input)
        let payload: [String: Any] = ["model": "qwen3:8b", "stream": false, "think": false, "format": "json", "options": ["temperature": temperature, "num_predict": limit],
            "messages": [["role": "system", "content": system], ["role": "user", "content": String(decoding: source, as: UTF8.self)]]]
        // Deliberately fixed to loopback: no cloud LLM or post-provided URL is contacted.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!); request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 100_000 else { throw InteractionError.invalid("本机 Ollama 未返回有效回复，请检查 qwen3:8b 服务") }
        struct Envelope: Decodable { struct Message: Decodable { var content: String }; var message: Message }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return Data(envelope.message.content.utf8)
    }
}
