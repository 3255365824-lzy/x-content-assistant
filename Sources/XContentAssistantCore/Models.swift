import Foundation

public enum RunConfiguration {
    public static func value(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key] ?? Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
    public static var isTest: Bool { value("XCONTENT_TEST_MODE") == "1" }
}

public enum DraftStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case queued
    case publishing
    case published
    case needsConfirmation = "needs_confirmation"
    case failed
}

public enum DraftCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case medical = "医学"
    case ai = "AI"
}

public enum MaterialStatus: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case new
    case draft
    case needsNote = "needs_note"
    case failed

    public var displayName: String {
        switch self {
        case .new: return "新素材"
        case .draft: return "已生成草稿"
        case .needsNote: return "需要补充说明"
        case .failed: return "处理失败"
        }
    }
}

public struct MediaAsset: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var relativePath: String
    public var kind: String
    public var madeWithAI: Bool

    public init(id: String = UUID().uuidString, relativePath: String, kind: String, madeWithAI: Bool) {
        self.id = id
        self.relativePath = relativePath
        self.kind = kind
        self.madeWithAI = madeWithAI
    }
}

public struct PublicationReceipt: Codable, Hashable, Sendable {
    public var kind: String?
    public var finalText: String?
    public var postID: String
    public var postURL: String
    public var publishedAt: Date
    public var finalTextHash: String
    public var includedSourceURL: Bool
    public var mediaID: String?

    public init(postID: String, postURL: String, publishedAt: Date, finalTextHash: String, includedSourceURL: Bool, mediaID: String?) {
        self.postID = postID
        self.postURL = postURL
        self.publishedAt = publishedAt
        self.finalTextHash = finalTextHash
        self.includedSourceURL = includedSourceURL
        self.mediaID = mediaID
    }
}

public struct MaterialItem: Codable, Identifiable, Hashable, Sendable {
    public var tags: [String]?
    public var favorite: Bool?
    public var archived: Bool?
    public var notes: String?
    public var reason: String?
    public var id: String
    public var category: DraftCategory
    public var relativePath: String
    public var fileType: String
    public var modifiedAt: Date
    public var status: MaterialStatus
    public var draftIDs: [String]

    public init(id: String, category: DraftCategory, relativePath: String, fileType: String, modifiedAt: Date, status: MaterialStatus, draftIDs: [String] = []) {
        self.id = id
        self.category = category
        self.relativePath = relativePath
        self.fileType = fileType
        self.modifiedAt = modifiedAt
        self.status = status
        self.draftIDs = draftIDs
    }
}

public struct DraftManifest: Codable, Identifiable, Hashable, Sendable {
    public var revision: Int = 0
    public var archived: Bool = false
    public var includeSourceURL: Bool = false
    public var order: Double = 0
    public var plannedAt: Date?
    public var card: CardConfig?
    public var versions: [DraftVersion] = []
    public var availableMedia: [MediaAsset] = []
    public var selectedVersionID: String?
    public var schema: Int
    public var id: String
    public var status: DraftStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var category: DraftCategory
    public var angle: String
    public var style: String
    public var postText: String
    public var sourceRelativePath: String
    public var sourceTitle: String?
    public var sourceDate: String?
    public var sourceURL: String?
    public var evidence: String
    public var media: [MediaAsset]
    public var lastError: String?
    public var publication: PublicationReceipt?

    public init(
        schema: Int = 3,
        id: String,
        status: DraftStatus = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        category: DraftCategory,
        angle: String,
        style: String = "bold_opinion",
        postText: String,
        sourceRelativePath: String,
        sourceTitle: String? = nil,
        sourceDate: String? = nil,
        sourceURL: String? = nil,
        evidence: String = "",
        media: [MediaAsset] = [],
        lastError: String? = nil,
        publication: PublicationReceipt? = nil
    ) {
        self.schema = schema
        self.id = id
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.category = category
        self.angle = angle
        self.style = style
        self.postText = postText
        self.sourceRelativePath = sourceRelativePath
        self.sourceTitle = sourceTitle
        self.sourceDate = sourceDate
        self.sourceURL = sourceURL
        self.evidence = evidence
        self.media = media
        self.lastError = lastError
        self.publication = publication
    }

    enum CodingKeys: String, CodingKey {
        case revision, archived, includeSourceURL, order, plannedAt, card, versions, availableMedia, selectedVersionID
        case schema, id, status, createdAt, updatedAt, category, angle, style, postText
        case sourceRelativePath, sourceTitle, sourceDate, sourceURL, evidence, media, lastError, publication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        id = try container.decode(String.self, forKey: .id)
        status = try container.decodeIfPresent(DraftStatus.self, forKey: .status) ?? .queued
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        category = try container.decode(DraftCategory.self, forKey: .category)
        angle = try container.decodeIfPresent(String.self, forKey: .angle) ?? "医学/AI观点"
        style = try container.decodeIfPresent(String.self, forKey: .style) ?? "bold_opinion"
        postText = try container.decode(String.self, forKey: .postText)
        sourceRelativePath = try container.decodeIfPresent(String.self, forKey: .sourceRelativePath) ?? ""
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceDate = try container.decodeIfPresent(String.self, forKey: .sourceDate)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        evidence = try container.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        media = try container.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        publication = try container.decodeIfPresent(PublicationReceipt.self, forKey: .publication)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        includeSourceURL = try container.decodeIfPresent(Bool.self, forKey: .includeSourceURL) ?? false
        order = try container.decodeIfPresent(Double.self, forKey: .order) ?? 0
        plannedAt = try container.decodeIfPresent(Date.self, forKey: .plannedAt)
        card = try container.decodeIfPresent(CardConfig.self, forKey: .card)
        versions = try container.decodeIfPresent([DraftVersion].self, forKey: .versions) ?? []
        availableMedia = try container.decodeIfPresent([MediaAsset].self, forKey: .availableMedia) ?? media
        selectedVersionID = try container.decodeIfPresent(String.self, forKey: .selectedVersionID)
    }
}

public struct ScheduleConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var times: [String]
    public var timezone: String
    public var maxPerRun: Int
    public var style: String

    public init(enabled: Bool = true, times: [String] = ["08:30", "13:30", "19:30"], timezone: String = "Asia/Shanghai", maxPerRun: Int = 1, style: String = "bold_opinion") {
        self.enabled = enabled
        self.times = times
        self.timezone = timezone
        self.maxPerRun = maxPerRun
        self.style = style
    }
}

public struct RuntimeHealth: Codable, Hashable, Sendable {
    public var n8n: Bool
    public var draftEngine: Bool
    public var ollama: Bool
    public var message: String

    public init(n8n: Bool = false, draftEngine: Bool = false, ollama: Bool = false, message: String = "未检查") {
        self.n8n = n8n
        self.draftEngine = draftEngine
        self.ollama = ollama
        self.message = message
    }

    public var allReady: Bool { n8n && draftEngine && ollama }
}

public struct GenerateResponse: Codable, Sendable {
    public var created: Int
    public var drafts: [GeneratedDraftSummary]
    public var draftPaths: [String]
    public var skipped: [String]
    public var style: String?
    public var message: String?

    public init(created: Int = 0, drafts: [GeneratedDraftSummary] = [], draftPaths: [String] = [], skipped: [String] = [], style: String? = nil, message: String? = nil) {
        self.created = created
        self.drafts = drafts
        self.draftPaths = draftPaths
        self.skipped = skipped
        self.style = style
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case created, drafts, draftPaths, skipped, style, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        created = try container.decodeIfPresent(Int.self, forKey: .created) ?? 0
        drafts = try container.decodeIfPresent([GeneratedDraftSummary].self, forKey: .drafts) ?? []
        draftPaths = try container.decodeIfPresent([String].self, forKey: .draftPaths) ?? []
        skipped = try container.decodeIfPresent([String].self, forKey: .skipped) ?? []
        style = try container.decodeIfPresent(String.self, forKey: .style)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

public struct GeneratedDraftSummary: Codable, Hashable, Sendable {
    public var id: String
    public var draftPath: String?
    public var category: String?
    public var angle: String?
    public var style: String?
    public var hook: String?
    public var post: String?
    public var intentURL: String?

    public init(id: String = "", draftPath: String? = nil, category: String? = nil, angle: String? = nil, style: String? = nil, hook: String? = nil, post: String? = nil, intentURL: String? = nil) {
        self.id = id
        self.draftPath = draftPath
        self.category = category
        self.angle = angle
        self.style = style
        self.hook = hook
        self.post = post
        self.intentURL = intentURL
    }

    enum CodingKeys: String, CodingKey { case id, draftPath, category, angle, style, hook, post, intentURL }
    enum AlternateCodingKeys: String, CodingKey { case intentUrl }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        draftPath = try container.decodeIfPresent(String.self, forKey: .draftPath)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        angle = try container.decodeIfPresent(String.self, forKey: .angle)
        style = try container.decodeIfPresent(String.self, forKey: .style)
        hook = try container.decodeIfPresent(String.self, forKey: .hook)
        post = try container.decodeIfPresent(String.self, forKey: .post)
        let alternate = try decoder.container(keyedBy: AlternateCodingKeys.self)
        intentURL = try container.decodeIfPresent(String.self, forKey: .intentURL)
            ?? alternate.decodeIfPresent(String.self, forKey: .intentUrl)
    }
}

public struct GenerateRequest: Codable, Sendable {
    public var style: String
    public var maxPerRun: Int
    public var requestID: String?

    public init(style: String, maxPerRun: Int = 1, requestID: String? = nil) {
        self.style = style
        self.maxPerRun = maxPerRun
        self.requestID = requestID
    }
}

public struct DraftUpdate: Codable, Sendable {
    public var postText: String
    public var sourceURL: String?

    public init(postText: String, sourceURL: String?) {
        self.postText = postText
        self.sourceURL = sourceURL
    }
}

public struct PublishMark: Codable, Sendable {
    public var finalText: String?
    public var postID: String
    public var postURL: String
    public var publishedAt: Date
    public var finalTextHash: String
    public var includedSourceURL: Bool
    public var mediaID: String?

    public init(postID: String, postURL: String, publishedAt: Date = Date(), finalTextHash: String, includedSourceURL: Bool, mediaID: String?) {
        self.postID = postID
        self.postURL = postURL
        self.publishedAt = publishedAt
        self.finalTextHash = finalTextHash
        self.includedSourceURL = includedSourceURL
        self.mediaID = mediaID
    }
}

public struct CardConfig: Codable, Hashable, Sendable {
    public var template: String
    public var hook: String
    public var fact: String
    public var ending: String
    public init(template: String = "bold_opinion", hook: String = "", fact: String = "", ending: String = "") {
        self.template = template; self.hook = hook; self.fact = fact; self.ending = ending
    }
}

public struct DraftVersion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var createdAt: Date
    public var label: String
    public var postText: String
    public var sourceURL: String?
    public var includeSourceURL: Bool?
    public var card: CardConfig?
    public var media: [MediaAsset]?
    public var evidence: String?
}

public struct GenerationJob: Codable, Identifiable, Sendable {
    public var id: String
    public var requestID: String
    public var status: String
    public var stage: String
    public var createdAt: Date
    public var updatedAt: Date
    public var error: String?
    public var result: GenerateResponse?
    public var isActive: Bool { status == "queued" || status == "running" }
}

public struct PublicationSnapshot: Identifiable, Sendable {
    public let id: String
    public let draft: DraftManifest
    public let account: XAccount
    public let finalText: String
    public let imageData: Data?
    public let imageHash: String?
    public init(draft: DraftManifest, account: XAccount, imageData: Data?) {
        id = UUID().uuidString; self.draft = draft; self.account = account; self.imageData = imageData
        finalText = XTextRules.composedText(postText: draft.postText, sourceURL: draft.sourceURL, includeSourceURL: draft.includeSourceURL)
        imageHash = imageData.map { TextHasher.sha256Data($0) }
    }
}

public struct XAccount: Codable, Hashable, Sendable {
    public var username: String
    public var userID: String

    public init(username: String, userID: String) {
        self.username = username
        self.userID = userID
    }
}
