import Foundation

/// Derived observations only. No copied replies, credentials or inferred user biography.
public struct ReplyStyleObservation: Codable, Sendable {
    public var id: String
    public var category: String
    public var name: String
    public var whenUseful: String
    public var pattern: String
    public var avoid: String
    public var parentURL: String
    public var replyURLs: [String]
    public var observedAt: Date
    public var enabled: Bool
}

public struct ReplyStyleProfile: Codable, Sendable {
    public var schema: Int
    public var observations: [ReplyStyleObservation]
    public init() { schema = 1; observations = [] }

    public func validate(now: Date = Date()) throws {
        guard schema == 1, observations.count <= 40, Set(observations.map(\.id)).count == observations.count else {
            throw InteractionError.invalid("风格参考格式不兼容或条目过多；可暂时关闭风格参考后生成")
        }
        for item in observations {
            guard item.id.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil,
                  ["AI", "医学", "通用"].contains(item.category),
                  (1...30).contains(item.name.count), (1...120).contains(item.whenUseful.count),
                  (1...180).contains(item.pattern.count), (1...180).contains(item.avoid.count),
                  (1...5).contains(item.replyURLs.count), item.observedAt <= now.addingTimeInterval(300) else {
                throw InteractionError.invalid("风格参考缺少可核对的来源、时间或有超长字段")
            }
            let parent = try InteractionRules.postID(from: item.parentURL)
            let replies = try item.replyURLs.map { try InteractionRules.postID(from: $0) }
            guard !replies.contains(parent), Set(replies).count == replies.count else {
                throw InteractionError.invalid("风格参考需指向真实回复，不可用原帖冒充回复")
            }
        }
    }

    public func notes(category: String) -> [String] {
        observations.filter { $0.enabled && ($0.category == category || $0.category == "通用") }.prefix(3).map {
            "适用：\($0.whenUseful)；接法：\($0.pattern)；不要：\($0.avoid)"
        }
    }
}
