import Foundation

/// Preferences are local metadata, not authority to fetch or publish anything.
public struct ReplyPreferences: Codable, Equatable, Sendable {
    public var discovery = ReplyDiscoveryPolicy()
    public var autoDraft = true
    public var tone = ReplyWritingRules.defaultTone
    public var useStyleReference = true
    public init() {}
    public func validate() throws {
        try discovery.validate()
        guard ReplyWritingRules.tones.contains(tone) else { throw InteractionError.invalid("回复语气设置无效，未覆盖原设置") }
    }
}

extension InteractionStore {
    public func loadReplyPreferences() throws -> ReplyPreferences {
        let value = try load().replyPreferences ?? ReplyPreferences()
        try value.validate(); return value
    }
    public func saveReplyPreferences(_ value: ReplyPreferences) throws {
        try value.validate()
        try transaction(write: true) { $0.replyPreferences = value }
    }
}
