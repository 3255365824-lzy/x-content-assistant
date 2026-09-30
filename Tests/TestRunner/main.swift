import Foundation
import XContentAssistantCore

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data("{}".utf8))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct CheckFailure: Error {
    let message: String
}

@discardableResult
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws -> Bool {
    guard try condition() else { throw CheckFailure(message: message) }
    return true
}

func run() throws {
    try check(XTextRules.weightedLength("医学AI") == 6, "weightedLength")
    try check(XTextRules.weightedLength("👨‍👩‍👧‍👦🙋🏽🇨🇳1️⃣") == 8, "compound emojis")
    try check(XTextRules.weightedLength("cafe\u{301}") == 4, "NFC normalization")
    try check(XTextRules.weightedLength("甲 https://example.com/a/long/path 乙") == 29, "embedded URL weight")
    try check(!XTextRules.validate(postText: "文案", sourceURL: "httpsbad://a", includeSourceURL: true).valid, "strict URL scheme")
    try check(ScheduleRules.normalizedTimes(["8:30", "08:30", "24:00", "08:30", "19:30"]) == ["08:30", "19:30"], "strict normalized schedules")
    try check(XTextRules.composedText(postText: "一句话", sourceURL: "https://example.com", includeSourceURL: false) == "一句话", "source URL off")
    try check(XTextRules.composedText(postText: "一句话", sourceURL: "https://example.com", includeSourceURL: true) == "一句话\nhttps://example.com", "source URL on")
    try check(!XTextRules.validate(postText: "可以", sourceURL: "ftp://example.com", includeSourceURL: true).valid, "invalid URL")
    try check(!XTextRules.validate(postText: String(repeating: "医", count: 141), sourceURL: nil, includeSourceURL: false).valid, "long text")
    try check(XTextRules.validate(postText: "一条足够短的测试内容", sourceURL: nil, includeSourceURL: false).valid, "short text")
    let urlLengthCheck = XTextRules.validate(postText: String(repeating: "医", count: 128), sourceURL: "https://example.com/a/very/long/source/path", includeSourceURL: true)
    try check(urlLengthCheck.valid && urlLengthCheck.weightedLength == 280, "X URL weighted length")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 8, minute: 30))!
    let config = ScheduleConfig(times: ["08:30"], timezone: "Asia/Shanghai")
    try check(ScheduleRules.slotKey(for: date, config: config, calendar: calendar) == "2026-09-23 08:30", "schedule slot")
    let next = ScheduleRules.nextRun(after: calendar.date(bySettingHour: 20, minute: 0, second: 0, of: date)!, config: ScheduleConfig(times: ["08:30", "13:30"], timezone: "Asia/Shanghai"), calendar: calendar)
    try check(calendar.component(.day, from: next!) == 24 && calendar.component(.hour, from: next!) == 8, "next run")

    let pkce = PKCEPair.make()
    try check(!pkce.verifier.isEmpty && !pkce.challenge.isEmpty && !pkce.challenge.contains("+"), "PKCE")

    let draft = DraftManifest(id: "runner-test", category: .medical, angle: "医学暴论", postText: "内容", sourceRelativePath: "医学/a.md")
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let encodedDraft = try encoder.encode(draft)
    let decodedDraft = try decoder.decode(DraftManifest.self, from: encodedDraft)
    try check(decodedDraft == draft, "manifest round trip")
    try check(DraftStateRules.canBeginPublishing(.queued), "queued can publish")
    try check(!DraftStateRules.canBeginPublishing(.needsConfirmation), "uncertain requires explicit resolution before retry")
    try check(!DraftStateRules.canBeginPublishing(.publishing), "publishing duplicate blocked")
    try check(!DraftStateRules.canBeginPublishing(.published), "published duplicate blocked")
    try check(XTextRules.basePostEstimateUSD == 0.015 && XTextRules.postWithURLEstimateUSD == 0.200, "cost estimates")

    let oldResponse = Data("{\"created\":1,\"message\":\"旧响应\",\"draftPaths\":[\"02_待发/a/草稿.md\"],\"skipped\":[]}".utf8)
    let decodedOld = try decoder.decode(GenerateResponse.self, from: oldResponse)
    try check(decodedOld.created == 1 && decodedOld.drafts.isEmpty && decodedOld.draftPaths.count == 1, "old generate response compatibility")
    let newResponse = Data("{\"created\":1,\"style\":\"bold_opinion\",\"drafts\":[{\"id\":\"draft-1\",\"draftPath\":\"02_待发/draft-1/草稿.md\",\"category\":\"医学\",\"post\":\"编辑后的内容\"}],\"draftPaths\":[\"02_待发/draft-1/草稿.md\"],\"skipped\":[]}".utf8)
    let decodedNew = try decoder.decode(GenerateResponse.self, from: newResponse)
    try check(decodedNew.drafts.first?.post == "编辑后的内容" && decodedNew.style == "bold_opinion", "new generate response")
    let requestData = try encoder.encode(GenerateRequest(style: "bold_opinion", maxPerRun: 1, requestID: "request-1"))
    try check(String(data: requestData, encoding: .utf8)?.contains("request-1") == true, "request ID")
}

func runXMock() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = XAPIClient(session: session, apiBaseURL: URL(string: "https://mock.local")!)
    MockURLProtocol.handler = { request in
        switch request.url?.path {
        case "/2/users/me":
            return (200, Data("{\"data\":{\"id\":\"42\",\"username\":\"mock_account\"}}".utf8))
        case "/2/media/upload":
            return (200, Data("{\"data\":{\"id\":\"media-1\"}}".utf8))
        case "/2/tweets":
            return (200, Data("{\"data\":{\"id\":\"post-1\",\"text\":\"最终编辑文案\"}}".utf8))
        default:
            return (404, Data("{\"error\":\"not found\"}".utf8))
        }
    }
    let account = try await client.currentUser(accessToken: "token")
    try check(account.username == "mock_account" && account.userID == "42", "current account")
    let mediaID = try await client.uploadPNG(Data([0, 1, 2]), accessToken: "token")
    try check(mediaID == "media-1", "media upload")
    let post = try await client.createPost(text: "最终编辑文案", mediaID: mediaID, madeWithAI: true, accessToken: "token")
    try check(post.id == "post-1", "post create")

    MockURLProtocol.handler = { _ in (401, Data("{\"title\":\"Unauthorized\"}".utf8)) }
    do {
        _ = try await client.createPost(text: "不会真的发出", mediaID: nil, madeWithAI: false, accessToken: "expired")
        throw CheckFailure(message: "401 was not surfaced")
    } catch let error as XClientError {
        if case .http(let status, _) = error {
            try check(status == 401, "401 status")
        } else {
            throw CheckFailure(message: "401 mapped to wrong error")
        }
    }
}

func runMaterialTests() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".test-tmp/core-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source.md")
    try Data("测试素材，原文件不变。".utf8).write(to: source)
    let runtime = LocalRuntimeClient(runtimeRoot: root.appendingPathComponent("runtime"))
    let imported = try runtime.importMaterial(file: source, category: .medical)
    let originalData = try Data(contentsOf: source), importedData = try Data(contentsOf: imported)
    try check(originalData == importedData, "source preserved on import")
    let duplicate = try runtime.importMaterial(file: source, category: .ai)
    try check(duplicate == imported, "duplicate content locates original across categories")
    let link = root.appendingPathComponent("alias")
    try fm.createSymbolicLink(at: link, withDestinationURL: source.deletingLastPathComponent())
    do { _ = try runtime.importMaterial(file: link.appendingPathComponent("source.md"), category: .ai); throw CheckFailure(message: "ancestor symlink allowed") }
    catch is RuntimeClientError { }
    let ai = root.appendingPathComponent("runtime/content-library/01_素材箱/AI")
    try fm.createSymbolicLink(at: ai, withDestinationURL: root)
    do { _ = try runtime.importMaterial(file: source, category: .ai); throw CheckFailure(message: "destination symlink allowed") }
    catch is RuntimeClientError { }
}

let group = DispatchGroup()
group.enter()
Task.detached {
    do {
        if let index = CommandLine.arguments.firstIndex(of: "--qa-bridge"), CommandLine.arguments.count > index + 1 {
            try qaBridgeFixture(CommandLine.arguments[index + 1]); print("isolated QA fixture updated; no browser or network"); group.leave(); return
        }
        try run()
        try runMaterialTests()
        try await runXMock()
        try runInteractionStoreTests()
        try runManualReplyTests()
        try runReplyWritingTests()
        try runReplyStyleProfileTests()
        try runReplyDiscoveryTests()
        try runDiscoveryBridgeTests()
        try runHotMaterialTests()
        try runOriginalIdeaTests()
        try runReplyDispatchTests()
        try await runInteractionNetworkTests()
        try await runHotMaterialNetworkTests()
        try await runOriginalNetworkTests()
        if CommandLine.arguments.contains("--live-reply-smoke") { try await liveReplySmoke() }
        if CommandLine.arguments.contains("--live-style-smoke") { try await liveStyleSmoke() }
        if CommandLine.arguments.contains("--loopback-bridge-smoke") { try await runLoopbackBridgeSmoke() }
        print("core tests passed")
    } catch let failure as CheckFailure {
        fputs("core test failed: \(failure.message)\n", stderr)
        exit(1)
    } catch {
        fputs("core test failed: \(error)\n", stderr)
        exit(1)
    }
    group.leave()
}
while group.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}
