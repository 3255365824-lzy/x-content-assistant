import Foundation
import XContentAssistantCore

func runReplyDiscoveryTests() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var policy = ReplyDiscoveryPolicy()
    let legacyPolicy = try JSONDecoder().decode(ReplyDiscoveryPolicy.self, from: Data(#"{"limit":20}"#.utf8))
    try check(legacyPolicy.source == "following" && legacyPolicy.limit == 20 && legacyPolicy.prioritizeLargeAccounts, "missing old preference fields get safe defaults")
    try rejects("decoded policy must validate") { _ = try JSONDecoder().decode(ReplyDiscoveryPolicy.self, from: Data(#"{"limit":999}"#.utf8)) }
    func post(_ id: String, _ user: String, followers: Int? = nil, age: Double = 600, likes: Int = 2) -> InteractionPost {
        var p = InteractionPost(id: id, text: "AI 工具展示具体功能时，演示与日常使用的场景可能不同。", username: user, category: "AI")
        p.discovery = ReplyDiscoveryEvidence(observedAt: now, publishedAt: now.addingTimeInterval(-age),
            postURL: "https://x.com/\(user)/status/\(id)", followers: followers,
            followersSourceURL: followers == nil ? nil : "https://x.com/\(user)", likes: likes)
        return p
    }
    let small = post("95001", "small", followers: 1000, likes: 10_000)
    let large = post("95002", "large", followers: 80_000)
    let unknown = post("95003", "unknown", likes: 1_000_000)
    var result = try ReplyDiscoveryRules.select([small, unknown, large], existingIDs: [], account: "me", policy: policy, now: now)
    try check(result.posts.first?.id == large.id && result.posts.count == 3, "large relevant account preferred, not an exclusive gate")
    try check(!ReplyDiscoveryRules.isLarge(unknown, policy: policy) && ReplyDiscoveryRules.reason(unknown, policy: policy).contains("未获取"), "engagement is not follower evidence")
    policy.largeAccountsOnly = true
    result = try ReplyDiscoveryRules.select([small, unknown, large], existingIDs: [], account: "me", policy: policy, now: now)
    try check(result.posts.map(\.id) == [large.id] && result.skipped.count == 2, "strict threshold excludes unknown")
    policy.largeAccountsOnly = false
    let stale = post("95004", "old", followers: 9_000_000, age: 60 * 3600)
    var reply = post("95005", "reply", followers: 900_000); reply.discovery!.isReply = true
    var ad = post("95006", "advert", followers: 900_000); ad.discovery!.isPromoted = true
    var incomplete = post("95007", "short", followers: 900_000); incomplete.discovery!.textComplete = false
    var spam = post("95008", "spam", followers: 900_000); spam.text = "AI 最新资讯，互关回关，一起来看看吧。"
    let own = post("95009", "Me", followers: 900_000)
    var irrelevant = post("95010", "other", followers: 900_000); irrelevant.category = "非法分类"
    result = try ReplyDiscoveryRules.select([stale, reply, ad, incomplete, spam, own, irrelevant, large], existingIDs: [], account: "me", policy: policy, now: now)
    try check(result.posts.map(\.id) == [large.id] && result.skipped.count == 7, "relevance, age, own, promotion, replies, truncated text gates")
    var everyday = post("95013", "daily", followers: 12_000)
    everyday.text = "年轻人越来越不想上班，老一辈却觉得坐办公室很舒服。"; everyday.category = InteractionRules.category(everyday.text)
    try check(everyday.category == "职场" && (try ReplyDiscoveryRules.select([everyday], existingIDs: [], account: "me", policy: policy, now: now)).posts.count == 1, "following now accepts non-medical non-AI topics")
    everyday.discovery!.visualContextMissing = true
    try check(try ReplyDiscoveryRules.select([everyday], existingIDs: [], account: "me", policy: policy, now: now).posts.isEmpty, "unseen image context not invented")
    var forged = large; forged.discovery!.followersSourceURL = "https://x.com/different"
    try rejects("metrics require same author profile") { try ReplyDiscoveryRules.validate(forged, now: now) }
    forged = large; forged.discovery!.postURL = "https://x.com/else/status/95002"
    try rejects("parent matches username") { try ReplyDiscoveryRules.validate(forged, now: now) }
    forged = large; forged.discovery!.postURL = "https://x.com.evil.invalid/large/status/95002"
    try rejects("host allowlist") { try ReplyDiscoveryRules.validate(forged, now: now) }
    forged = large; forged.discovery!.followers = -1
    try rejects("negative metrics") { try ReplyDiscoveryRules.validate(forged, now: now) }
    forged = large; forged.discovery!.observedAt = now.addingTimeInterval(-7200)
    try rejects("old observation not this fetch") { try ReplyDiscoveryRules.validate(forged, now: now) }
    forged = large; forged.discovery!.publishedAt = now.addingTimeInterval(3600)
    try rejects("future publication date") { try ReplyDiscoveryRules.validate(forged, now: now) }
    result = try ReplyDiscoveryRules.select([large, post("95011", "LARGE", followers: 80_000), post("95012", "large", followers: 80_000), small], existingIDs: [], account: "me", policy: policy, now: now)
    try check(result.posts.filter { $0.username.lowercased() == "large" }.count == 2 && result.posts.contains(where: { $0.id == small.id }), "per-author quota prevents monopolizing batch")
    policy.limit = 1
    result = try ReplyDiscoveryRules.select([large, small], existingIDs: [], account: "me", policy: policy, now: now)
    try check(result.posts.count == 1 && result.skipped.count == 1, "batch cap")
    policy.limit = 51
    try rejects("oversized batch configuration") { _ = try ReplyDiscoveryRules.select([large], existingIDs: [], account: "me", policy: policy, now: now) }
    policy = ReplyDiscoveryPolicy()
    let oldJSON = #"{"id":"95300","text":"旧版 AI 原帖完整文字。","username":"old","category":"AI","origin":"手动粘贴"}"#
    let oldPost = try JSONDecoder().decode(InteractionPost.self, from: Data(oldJSON.utf8))
    try check(oldPost.discovery == nil && !ReplyDiscoveryRules.isLarge(oldPost, policy: policy), "old data decodes without invented followers")

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-tmp/discovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = InteractionStore(root: root)
    _ = try store.collect([small, unknown])
    try store.edit(small.id, text: "自己改过的回复，不能刷新就被覆盖。")
    try store.edit(unknown.id, text: "已交接到网页的一条回复。")
    _ = try store.markOpened(unknown.id, expectedText: "已交接到网页的一条回复。")
    let before = try store.load().items
    var changed = small; changed.text = "AI 原文已经变化，但不能清空正在编辑的旧记录。"
    result = try store.importDiscovered([changed, unknown, large], account: "me", policy: policy, now: now)
    try check(result.posts.map(\.id) == [large.id], "only unseen posts added")
    let after = try store.load().items
    for item in before { try check(after.first(where: { $0.id == item.id }) == item, "existing editor, handoff and receipt preserved exactly") }
    try check(after.first?.state == .unread && after.first?.dispatch == nil && after.first?.record == nil && after.first?.candidates.isEmpty == true, "collection grants no publication authority or invented reply")
    let repeatResult = try store.importDiscovered([large], account: "me", now: now)
    try check(repeatResult.posts.isEmpty && repeatResult.skipped.count == 1 && (try store.load()).items.count == 3, "repeat fetch idempotent for posts")
    let beforePreferences = try store.load().items
    var preferences = ReplyPreferences(); preferences.discovery.limit = 50; preferences.discovery.followerThreshold = 50_000
    preferences.autoDraft = false; preferences.useStyleReference = false
    try store.saveReplyPreferences(preferences)
    try check(try InteractionStore(root: root).loadReplyPreferences() == preferences, "local preferences survive store restart")
    try check(try store.load().items == beforePreferences, "preference save preserves posts and editor state")
    preferences.tone = "invalid"
    try rejects("invalid settings never overwrite existing preferences") { try store.saveReplyPreferences(preferences) }
    try check(try store.loadReplyPreferences().tone == ReplyWritingRules.defaultTone, "bad preference write leaves valid settings intact")
    let groups = ReplyDiscoverySkipSummary.grouped(result.skipped + result.skipped)
    try check(groups.reduce(0) { $0 + $1.count } == result.skipped.count * 2, "skip reasons aggregate without losing counts")
    print("discovery tests passed: large-account ranking, evidence, freshness, relevance, limits, old data, exact editor preservation, duplicate exclusion; simulated only")
}
