import Foundation
import CryptoKit

public enum ReplyDispatchState: String, Codable, Sendable {
    case queued, preparing, clickCommitted, sent, blocked, uncertain, cancelled
    public var label: String {
        switch self {
        case .queued: "已确认，等待 Codex"
        case .preparing: "正在核对网页"
        case .clickCommitted: "正在发送 / 核验结果"
        case .sent: "网页核验成功"
        case .blocked: "尚未发送 · 需要处理"
        case .uncertain: "结果不确定 · 禁止重发"
        case .cancelled: "已撤销，未执行"
        }
    }
}

/// Immutable user-reviewed payload. This is not an API credential or a browser session.
public struct ReplyApproval: Codable, Equatable, Sendable {
    public let id: String
    public let post: InteractionPost
    public let text: String
    public let account: String
    public let approvedAt: Date
    public let expiresAt: Date
    public let sha256: String
    public let testOnly: Bool
    init(post: InteractionPost, text: String, account: String, now: Date, testOnly: Bool) throws {
        id = UUID().uuidString; self.post = post; self.text = text; self.account = try ReplyDispatchRules.account(account)
        // JSON ISO8601 persistence has whole-second resolution. Hash that same representation.
        approvedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)); expiresAt = approvedAt.addingTimeInterval(1800)
        self.testOnly = testOnly
        sha256 = Self.digest(id: id, post: post, text: text, account: self.account, approvedAt: approvedAt, expiresAt: expiresAt, testOnly: testOnly)
    }
    static func digest(id: String, post: InteractionPost, text: String, account: String, approvedAt: Date, expiresAt: Date, testOnly: Bool) -> String {
        // Length-prefixed fields prevent delimiter ambiguity; includes the complete approved source context.
        let fields = [id, post.id, post.text, post.username, text, account, String(Int(approvedAt.timeIntervalSince1970)), String(Int(expiresAt.timeIntervalSince1970)), String(testOnly)]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        try InteractionRules.validateSource(post); try InteractionRules.validateReply(text)
        guard try ReplyDispatchRules.account(account) == account,
              sha256 == Self.digest(id: id, post: post, text: text, account: account, approvedAt: approvedAt, expiresAt: expiresAt, testOnly: testOnly)
        else { throw InteractionError.invalid("审核快照不完整或已经变化，请停止执行") }
    }
}

public struct ReplyDispatch: Codable, Equatable, Identifiable, Sendable {
    public var id: String { approval.id }
    public let approval: ReplyApproval
    public var state: ReplyDispatchState = .queued
    public var updatedAt: Date
    public var claimToken: String?
    public var claimedAt: Date?
    public var clickCommittedAt: Date?
    public var receiptURL: String?
    public var reason = "等待 Codex 定时检查；这还不是发送成功。"
}

public struct ReplyExecutorStatus: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var message: String
    public init(checkedAt: Date = Date(), message: String) { self.checkedAt = checkedAt; self.message = message }
}

/// Captured by the executor from the visible webpage, never inferred from stored credentials.
public struct ReplyPageObservation: Codable, Sendable {
    public var account: String
    public var parentPostID: String
    public var replyText: String
    public var sourceContextMatches: Bool
    public init(account: String, parentPostID: String, replyText: String, sourceContextMatches: Bool) {
        self.account = account; self.parentPostID = parentPostID; self.replyText = replyText; self.sourceContextMatches = sourceContextMatches
    }
}

public enum ReplyDispatchRules {
    public static func account(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^@", with: "", options: .regularExpression).lowercased()
        guard value.range(of: "^[a-z0-9_]{1,15}$", options: .regularExpression) != nil else { throw InteractionError.invalid("请输入有效的 X 用户名（@ 后面的账号，不是昵称）") }
        return value
    }
    static func verify(_ observation: ReplyPageObservation, approval: ReplyApproval) throws {
        try approval.validate()
        guard try account(observation.account) == approval.account else { throw InteractionError.invalid("浏览器账号不一致，未授权点击发送") }
        guard observation.parentPostID == approval.post.id, observation.sourceContextMatches else { throw InteractionError.invalid("原帖或上下文不一致，未授权点击发送") }
        guard observation.replyText == approval.text else { throw InteractionError.invalid("网页输入文字与审核快照不一致，未授权点击发送") }
    }
}

extension InteractionStore {
    /// Only the App's explicit review-confirm action calls this; the executor CLI has no approval command.
    public func approveReply(_ snapshot: InteractionItem, account: String, testOnly: Bool = false, now: Date = Date()) throws -> ReplyDispatch {
        guard try load().manualRepliesOnly != true else { throw InteractionError.invalid("当前为手动发送模式，不创建代发批准") }
        var dispatch: ReplyDispatch!
        _ = try update(snapshot.id) { item in
            guard item.editable, item.state != .skipped, item.replyText == snapshot.replyText, item.post == snapshot.post else {
                throw InteractionError.invalid("内容已变化、已提交或需核对，请返回重新审核")
            }
            try InteractionRules.validateReply(item.replyText)
            let approval = try ReplyApproval(post: item.post, text: item.replyText, account: account, now: now, testOnly: testOnly)
            try approval.validate()
            if let previous = item.dispatch { item.dispatchHistory = (item.dispatchHistory ?? []) + [previous] }
            dispatch = ReplyDispatch(approval: approval, updatedAt: now)
            item.dispatch = dispatch; item.state = .approved
            item.review = ReplyReview(text: approval.text, reviewedAt: approval.approvedAt, sourceText: approval.post.text)
        }
        return dispatch
    }
    public func cancelReply(_ id: String, now: Date = Date()) throws {
        _ = try update(id) { item in
            guard var job = item.dispatch, [.queued, .preparing].contains(job.state) else {
                throw InteractionError.invalid("已进入发送核验阶段，不能撤销或重发；请等待结果")
            }
            job.state = .cancelled; job.updatedAt = now; job.reason = "用户在发送点击前撤销"; item.dispatch = job
            item.state = .ready; item.review = nil
        }
    }
    /// Timed out preparation is NOT auto-requeued. Crossing the click boundary is always uncertain.
    @discardableResult public func reconcileReplies(now: Date = Date()) throws -> InteractionDatabase {
        let current = try load()
        func needsRecovery(_ job: ReplyDispatch) -> Bool {
            (job.state == .queued && job.approval.expiresAt <= now) ||
            (job.state == .preparing && now.timeIntervalSince(job.claimedAt ?? job.updatedAt) >= 300) ||
            (job.state == .clickCommitted && now.timeIntervalSince(job.clickCommittedAt ?? job.updatedAt) >= 120)
        }
        guard current.items.contains(where: { $0.dispatch.map(needsRecovery) ?? false }) else { return current }
        return try transaction(write: true) { db in
            for i in db.items.indices {
                guard var job = db.items[i].dispatch, needsRecovery(job) else { continue }
                if job.state == .clickCommitted {
                    job.state = .uncertain; job.reason = "发送点击后未得到明确回执。只能核对，不会自动重发。"; db.items[i].state = .uncertain
                } else {
                    job.state = .blocked; job.reason = "等待或网页核对超时，未取得发送许可。请重新审核后提交。"; db.items[i].state = .ready
                }
                job.updatedAt = now; db.items[i].dispatch = job
            }
            return db
        }
    }
    public func pulse(message: String, now: Date = Date()) throws {
        guard message.count <= 500 else { throw InteractionError.invalid("执行器状态过长") }
        try transaction(write: true) { $0.executor = ReplyExecutorStatus(checkedAt: now, message: message) }
    }
    private func mutateJob<T>(_ jobID: String, _ body: (inout InteractionItem, inout ReplyDispatch) throws -> T) throws -> T {
        try transaction(write: true) { db in
            guard let i = db.items.firstIndex(where: { $0.dispatch?.id == jobID }), var job = db.items[i].dispatch else { throw InteractionError.invalid("发送任务不存在或已被新审核替换") }
            try job.approval.validate()
            guard job.approval.text == db.items[i].replyText, job.approval.post == db.items[i].post else { throw InteractionError.invalid("任务快照与当前内容不一致，停止执行") }
            let value = try body(&db.items[i], &job); db.items[i].dispatch = job
            return value
        }
    }
    public func claimReply(_ jobID: String, testExecutor: Bool = false, now: Date = Date()) throws -> ReplyDispatch {
        try transaction(write: true) { db in
            guard db.manualRepliesOnly != true else { throw InteractionError.invalid("手动发送模式禁止执行器领取任务") }
            // Only one browser operation at a time, even across independent executor processes.
            guard !db.items.contains(where: { [.preparing, .clickCommitted].contains($0.dispatch?.state ?? .cancelled) }) else { throw InteractionError.invalid("已有网页任务在执行，请勿并行操作浏览器") }
            guard let i = db.items.firstIndex(where: { $0.dispatch?.id == jobID }), var job = db.items[i].dispatch else { throw InteractionError.invalid("发送任务不存在") }
            try job.approval.validate()
            guard job.state == .queued, job.approval.expiresAt > now, job.approval.testOnly == testExecutor,
                  job.approval.text == db.items[i].replyText, job.approval.post == db.items[i].post else { throw InteractionError.invalid("任务已过期、被撤销、内容变化或不是当前执行环境；禁止发送") }
            job.state = .preparing; job.claimToken = UUID().uuidString; job.claimedAt = now; job.updatedAt = now
            job.reason = "Codex 正在核对账号、原帖和输入文字；此时尚未点击发送。"
            db.items[i].state = .sending; db.items[i].dispatch = job; return job
        }
    }
    /// Must be durably saved immediately BEFORE the single irreversible webpage click.
    /// Even if the executor crashes before actually clicking, this approval cannot be reused.
    public func commitReplyClick(_ jobID: String, token: String, observation: ReplyPageObservation, now: Date = Date()) throws -> ReplyDispatch {
        try mutateJob(jobID) { item, job in
            guard job.state == .preparing, job.claimToken == token, job.approval.expiresAt > now,
                  now.timeIntervalSince(job.claimedAt ?? .distantPast) < 300 else { throw InteractionError.invalid("执行许可已撤销或过期，请勿点击发送") }
            try ReplyDispatchRules.verify(observation, approval: job.approval)
            job.state = .clickCommitted; job.clickCommittedAt = now; job.updatedAt = now
            job.reason = "已锁定一次发送操作，正在核验网页回执。未拿到明确结果前绝不重发。"
            item.state = .uncertain; return job
        }
    }
    public func blockReply(_ jobID: String, token: String, reason: String, now: Date = Date()) throws {
        guard !reason.isEmpty, reason.count <= 1000 else { throw InteractionError.invalid("请提供简短、无敏感数据的失败原因") }
        try mutateJob(jobID) { item, job in
            guard job.state == .preparing, job.claimToken == token else { throw InteractionError.invalid("只有点击前的任务可以登记为未发送") }
            job.state = .blocked; job.reason = reason; job.updatedAt = now; item.state = .ready
        }
    }
    public func uncertainReply(_ jobID: String, token: String, reason: String, now: Date = Date()) throws {
        guard !reason.isEmpty, reason.count <= 1000 else { throw InteractionError.invalid("请提供简短的核对原因") }
        try mutateJob(jobID) { item, job in
            guard [.clickCommitted, .uncertain].contains(job.state), job.claimToken == token else { throw InteractionError.invalid("此任务未进入发送阶段") }
            job.state = .uncertain; job.updatedAt = now; job.reason = reason; item.state = .uncertain
        }
    }
    public func recordBrowserReply(_ jobID: String, token: String, url: String, observation: ReplyPageObservation, now: Date = Date()) throws {
        let replyID = try InteractionRules.postID(from: url)
        try mutateJob(jobID) { item, job in
            try ReplyDispatchRules.verify(observation, approval: job.approval)
            let canonicalURL = "https://x.com/\(job.approval.account)/status/\(replyID)"
            guard job.claimToken == token else { throw InteractionError.invalid("回执执行令牌不匹配") }
            let path = URLComponents(string: url)?.path.split(separator: "/").map(String.init) ?? []
            guard replyID != item.id, path.count == 3, path[0].lowercased() == job.approval.account else { throw InteractionError.invalid("回执必须是目标账号发出的另一条帖子，不接受原帖或匿名跳转链接") }
            if job.state == .sent && job.receiptURL == canonicalURL { return } // Idempotent receipt, never a resend.
            guard [.clickCommitted, .uncertain].contains(job.state), job.claimToken == token else { throw InteractionError.invalid("没有待核验的发送任务，不能伪造成功状态") }
            job.state = .sent; job.receiptURL = canonicalURL; job.updatedAt = now; job.reason = "已通过网页核对发送账号、回复原帖、最终文字和永久链接；不是 API 回执。"
            var record = ReplyRecord(url: canonicalURL, finalText: job.approval.text, recordedAt: now)
            record.kind = job.approval.testOnly ? "simulated_browser_verified" : "browser_verified"
            item.record = record; item.state = .sent
        }
    }
}
