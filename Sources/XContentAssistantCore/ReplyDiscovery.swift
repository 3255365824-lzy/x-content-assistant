import Foundation

/// Visible public evidence only. No cookies, authorization tokens or inferred follower counts.
public struct ReplyDiscoveryEvidence: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var publishedAt: Date
    public var postURL: String
    public var followers: Int?
    public var followersSourceURL: String?
    public var likes: Int?
    public var replies: Int?
    public var isReply: Bool
    public var isPromoted: Bool
    public var textComplete: Bool
    public var visualContextMissing: Bool?
    public init(observedAt: Date, publishedAt: Date, postURL: String, followers: Int? = nil,
                followersSourceURL: String? = nil, likes: Int? = nil, replies: Int? = nil,
                isReply: Bool = false, isPromoted: Bool = false, textComplete: Bool = true) {
        self.observedAt = observedAt; self.publishedAt = publishedAt; self.postURL = postURL
        self.followers = followers; self.followersSourceURL = followersSourceURL
        self.likes = likes; self.replies = replies; self.isReply = isReply
        self.isPromoted = isPromoted; self.textComplete = textComplete
    }
}

public struct ReplyDiscoveryPolicy: Codable, Equatable, Sendable {
    public var source = "following"
    public var followerThreshold = 10_000
    public var prioritizeLargeAccounts = true
    public var largeAccountsOnly = false
    public var maxAgeHours = 48
    public var limit = 10
    public var maxPerAuthor = 2
    public init() {}
    private enum CodingKeys: String, CodingKey { case source, followerThreshold, prioritizeLargeAccounts, largeAccountsOnly, maxAgeHours, limit, maxPerAuthor }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "following"
        followerThreshold = try values.decodeIfPresent(Int.self, forKey: .followerThreshold) ?? 10_000
        prioritizeLargeAccounts = try values.decodeIfPresent(Bool.self, forKey: .prioritizeLargeAccounts) ?? true
        largeAccountsOnly = try values.decodeIfPresent(Bool.self, forKey: .largeAccountsOnly) ?? false
        maxAgeHours = try values.decodeIfPresent(Int.self, forKey: .maxAgeHours) ?? 48
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? 10
        maxPerAuthor = try values.decodeIfPresent(Int.self, forKey: .maxPerAuthor) ?? 2
        try validate()
    }
    public func validate() throws {
        guard ["following", "discover"].contains(source), (1_000...100_000_000).contains(followerThreshold), (1...168).contains(maxAgeHours),
              (1...50).contains(limit), (1...5).contains(maxPerAuthor) else {
            throw InteractionError.invalid("选帖范围无效：每批 1–50 条，单作者最多 1–5 条，新鲜度不超过 7 天")
        }
    }
}

public struct ReplyDiscoverySkip: Codable, Equatable, Sendable {
    public var id: String
    public var reason: String
}

public struct ReplyDiscoverySkipSummary: Identifiable, Equatable, Sendable {
    public var reason: String
    public var count: Int
    public var id: String { reason }
    public static func grouped(_ skips: [ReplyDiscoverySkip]) -> [Self] {
        Dictionary(grouping: skips, by: \.reason).map { Self(reason: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.reason < $1.reason : $0.count > $1.count }
    }
}

public struct ReplyDiscoverySelection: Codable, Sendable {
    public var posts: [InteractionPost]
    public var skipped: [ReplyDiscoverySkip]
}

public enum ReplyDiscoveryRules {
    public static func validate(_ post: InteractionPost, now: Date) throws {
        try InteractionRules.validateSource(post)
        guard let evidence = post.discovery,
              post.username.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil,
              InteractionRules.categories.contains(post.category),
              (-300...3600).contains(now.timeIntervalSince(evidence.observedAt)),
              evidence.publishedAt <= now.addingTimeInterval(300),
              try InteractionRules.postID(from: evidence.postURL) == post.id else {
            throw InteractionError.invalid("缺少可核对的原帖、作者、分类或本轮观察时间")
        }
        let path = URLComponents(string: evidence.postURL)?.path.split(separator: "/").map(String.init) ?? []
        guard path.count == 3, path[0].lowercased() == post.username.lowercased() else {
            throw InteractionError.invalid("原帖链接与作者不一致")
        }
        for count in [evidence.followers, evidence.likes, evidence.replies].compactMap({ $0 }) {
            guard (0...10_000_000_000).contains(count) else { throw InteractionError.invalid("粉丝数或互动数格式无效") }
        }
        if evidence.followers != nil {
            guard let raw = evidence.followersSourceURL, let url = URLComponents(string: raw),
                  url.scheme == "https", ["x.com", "www.x.com"].contains(url.host?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path.lowercased() == "/" + post.username.lowercased() else {
                throw InteractionError.invalid("粉丝数必须附同一作者的公开主页来源；不可用蓝标或点赞数推测")
            }
        }
    }

    public static func isLarge(_ post: InteractionPost, policy: ReplyDiscoveryPolicy) -> Bool {
        guard let evidence = post.discovery, evidence.followersSourceURL != nil, let count = evidence.followers else { return false }
        return count >= policy.followerThreshold
    }

    public static func reason(_ post: InteractionPost, policy: ReplyDiscoveryPolicy) -> String {
        guard let evidence = post.discovery else { return "旧素材 · 影响力未核对" }
        let followers = evidence.followers.map { "可见粉丝数约 \($0.formatted())" } ?? "粉丝数未获取"
        return (isLarge(post, policy: policy) ? "大号优先 · " : "相关新帖 · ") + followers
    }

    public static func ordered(_ posts: [InteractionPost], policy: ReplyDiscoveryPolicy) -> [InteractionPost] {
        posts.sorted { left, right in
            if policy.prioritizeLargeAccounts {
                let a = isLarge(left, policy: policy), b = isLarge(right, policy: policy)
                if a != b { return a }
            }
            // Freshness before raw engagement: old viral posts must not monopolize the queue.
            let a = left.discovery?.publishedAt ?? .distantPast, b = right.discovery?.publishedAt ?? .distantPast
            let bucketA = Int(a.timeIntervalSince1970 / 21600), bucketB = Int(b.timeIntervalSince1970 / 21600)
            if bucketA != bucketB { return bucketA > bucketB }
            let engagementA = (left.discovery?.likes ?? 0) + (left.discovery?.replies ?? 0)
            let engagementB = (right.discovery?.likes ?? 0) + (right.discovery?.replies ?? 0)
            if engagementA != engagementB { return engagementA > engagementB }
            if a != b { return a > b }
            return left.id < right.id
        }
    }

    public static func select(_ posts: [InteractionPost], existingIDs: Set<String>, account: String,
                              policy: ReplyDiscoveryPolicy = ReplyDiscoveryPolicy(), now: Date = Date()) throws -> ReplyDiscoverySelection {
        try policy.validate()
        guard posts.count <= 200, account.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil else {
            throw InteractionError.invalid("最多检查 200 条可见帖子，并需核对当前账号以排除自己的帖子")
        }
        var eligible: [InteractionPost] = [], skipped: [ReplyDiscoverySkip] = [], seen = existingIDs
        for post in posts {
            if seen.contains(post.id) { skipped.append(.init(id: post.id, reason: "已在互动箱中，不重复加入或重置状态")); continue }
            do { try validate(post, now: now) }
            catch { skipped.append(.init(id: post.id, reason: error.localizedDescription)); continue }
            let evidence = post.discovery!
            let reason: String?
            if post.username.lowercased() == account.lowercased() { reason = "自己的帖子" }
            else if evidence.isPromoted { reason = "推广内容" }
            else if evidence.isReply { reason = "评论而非新原帖" }
            else if !evidence.textComplete { reason = "正文不完整，需先展开核对" }
            else if evidence.visualContextMissing == true { reason = "接话需要配图或视频上下文，先跳过" }
            else if now.timeIntervalSince(evidence.publishedAt) > Double(policy.maxAgeHours * 3600) { reason = "超出新帖时间范围" }
            else if policy.largeAccountsOnly && !isLarge(post, policy: policy) { reason = "不满足大号门槛或粉丝数未知" }
            else if post.text.range(of: "互关|互fo|回关|邀请码|返佣|刷粉|follow.?back", options: [.regularExpression, .caseInsensitive]) != nil { reason = "互关或推广招揽" }
            else { reason = nil }
            if let reason { skipped.append(.init(id: post.id, reason: reason)); continue }
            seen.insert(post.id); eligible.append(post)
        }
        var selected: [InteractionPost] = [], authors: [String: Int] = [:]
        for post in ordered(eligible, policy: policy) {
            let author = post.username.lowercased()
            if (authors[author] ?? 0) >= policy.maxPerAuthor { skipped.append(.init(id: post.id, reason: "本批同一作者条数已达上限")); continue }
            if selected.count >= policy.limit { skipped.append(.init(id: post.id, reason: "本批条数已满")); continue }
            selected.append(post); authors[author, default: 0] += 1
        }
        return ReplyDiscoverySelection(posts: selected, skipped: skipped)
    }
}

extension InteractionStore {
    /// Atomic deduplication; never invokes collect(), which may reset an edited source.
    public func importDiscovered(_ posts: [InteractionPost], account: String,
                                 policy: ReplyDiscoveryPolicy = ReplyDiscoveryPolicy(), now: Date = Date()) throws -> ReplyDiscoverySelection {
        try transaction(write: true) { db in
            let result = try ReplyDiscoveryRules.select(posts, existingIDs: Set(db.items.map(\.id)), account: account, policy: policy, now: now)
            guard db.items.count + result.posts.count <= 1000 else { throw InteractionError.invalid("互动箱已达容量上限，旧记录未覆盖") }
            for var post in result.posts.reversed() {
                post.origin = policy.source == "following" ? "Edge 正在关注 · 不限话题" : "Edge 关键词发现 · 医学/AI"
                post.sourceAccountID = nil
                var item = InteractionItem(post: post)
                item.note = ReplyDiscoveryRules.reason(post, policy: policy) + "；仅供审核，不代表事实已核实。"
                item.updatedAt = now
                db.items.insert(item, at: 0)
            }
            db.lastFetchedAt = now
            return result
        }
    }
}
