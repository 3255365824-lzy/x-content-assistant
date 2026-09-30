import Foundation
import CryptoKit

public enum RuntimeClientError: LocalizedError, Sendable {
    case invalidResponse
    case http(status: Int, message: String)
    case serviceUnavailable(String)
    case invalidPath

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "本地服务返回了无法识别的结果"
        case .http(let status, let message): return "本地服务错误 \(status)：\(message)"
        case .serviceUnavailable(let message): return message
        case .invalidPath: return "草稿路径不合法"
        }
    }
}

public final class LocalRuntimeClient: @unchecked Sendable {
    public let runtimeRoot: URL
    public let engineBaseURL: URL
    public let n8nBaseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(runtimeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("n8n-x-assistant"), session: URLSession = .shared) {
        self.runtimeRoot = RunConfiguration.value("XCONTENT_RUNTIME_ROOT").map { URL(fileURLWithPath: $0) } ?? runtimeRoot
        self.engineBaseURL = URL(string: RunConfiguration.value("XCONTENT_ENGINE_URL") ?? "http://127.0.0.1:8765")!
        self.n8nBaseURL = URL(string: RunConfiguration.value("XCONTENT_N8N_URL") ?? "http://127.0.0.1:5678")!
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO-8601 date")
        }
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func health() async -> RuntimeHealth {
        async let engine = probe(engineBaseURL.appendingPathComponent("healthz"))
        async let n8n = probe(n8nBaseURL.appendingPathComponent("healthz"))
        let engineOK = await engine
        let n8nOK = await n8n
        let ollamaOK = await probe(URL(string: "http://127.0.0.1:11434/api/tags")!)
        let message = engineOK && n8nOK && ollamaOK ? "本地服务正常" : "部分本地服务未就绪"
        return RuntimeHealth(n8n: n8nOK, draftEngine: engineOK, ollama: ollamaOK, message: message)
    }

    public func listDrafts() async throws -> [DraftManifest] {
        let data = try await request(url: engineBaseURL.appendingPathComponent("api/v1/drafts"), method: "GET")
        return try decoder.decode([DraftManifest].self, from: data)
    }

    public func listMaterials() async throws -> [MaterialItem] {
        let data = try await request(url: engineBaseURL.appendingPathComponent("api/v1/materials"), method: "GET")
        return try decoder.decode([MaterialItem].self, from: data)
    }

    public func reconcilePublishing() async throws {
        _ = try await request(url: engineBaseURL.appendingPathComponent("api/v1/drafts/reconcile"), method: "POST")
    }

    public func generate(style: String, maxPerRun: Int = 1, requestID: String? = nil) async throws -> GenerateResponse {
        let body = try encoder.encode(GenerateRequest(style: style, maxPerRun: max(1, min(3, maxPerRun)), requestID: requestID ?? UUID().uuidString))
        let url = n8nBaseURL.appendingPathComponent("webhook/x-content-app/generate")
        let data = try await request(url: url, method: "POST", body: body, contentType: "application/json", timeout: 900)
        return try decoder.decode(GenerateResponse.self, from: data)
    }

    public func updateDraft(id: String, update: DraftUpdate) async throws -> DraftManifest {
        let body = try encoder.encode(update)
        let url = try draftURL(id: id).appendingPathComponent("update")
        let data = try await request(url: url, method: "PATCH", body: body, contentType: "application/json")
        return try decoder.decode(DraftManifest.self, from: data)
    }

    public func markPublished(id: String, mark: PublishMark) async throws -> DraftManifest {
        let body = try encoder.encode(mark)
        let url = try draftURL(id: id).appendingPathComponent("mark-published")
        let data = try await request(url: url, method: "POST", body: body, contentType: "application/json")
        return try decoder.decode(DraftManifest.self, from: data)
    }

    public func beginPublishing(id: String) async throws -> DraftManifest {
        let url = try draftURL(id: id).appendingPathComponent("begin-publishing")
        let data = try await request(url: url, method: "POST")
        return try decoder.decode(DraftManifest.self, from: data)
    }

    public func markFailed(id: String, message: String) async throws -> DraftManifest {
        let body = try encoder.encode(["message": message])
        let url = try draftURL(id: id).appendingPathComponent("failed")
        let data = try await request(url: url, method: "POST", body: body, contentType: "application/json")
        return try decoder.decode(DraftManifest.self, from: data)
    }

    public func markNeedsConfirmation(id: String, message: String) async throws -> DraftManifest {
        let body = try encoder.encode(["message": message])
        let url = try draftURL(id: id).appendingPathComponent("needs-confirmation")
        let data = try await request(url: url, method: "POST", body: body, contentType: "application/json")
        return try decoder.decode(DraftManifest.self, from: data)
    }

    public func importMaterial(file: URL, category: DraftCategory) throws -> URL {
        try rejectSymbolicLinks(file)
        try rejectSymbolicLinks(runtimeRoot.appendingPathComponent("content-library/01_素材箱/" + category.rawValue))
        let supported = ["png", "jpg", "jpeg", "webp", "gif", "heic", "tif", "tiff", "pdf", "docx", "pptx", "txt", "md", "rtf", "html", "htm"]
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, supported.contains(file.pathExtension.lowercased()), (info.fileSize ?? 0) > 0, (info.fileSize ?? 0) <= 50_000_000 else {
            throw RuntimeClientError.http(status: 400, message: "请导入支持的普通文件，大小须在 1 字节到 50 MB 之间；不支持符号链接")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        let inbox = runtimeRoot.appendingPathComponent("content-library/01_素材箱")
        if let enumerator = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            for case let existing as URL in enumerator {
                guard (try? rejectSymbolicLinks(existing)) != nil else { continue }
                let value = try existing.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if value.isRegularFile == true && value.isSymbolicLink != true && value.fileSize == info.fileSize,
                   SHA256.hash(data: try Data(contentsOf: existing, options: .mappedIfSafe)) == digest { return existing }
            }
        }
        let folder = runtimeRoot
            .appendingPathComponent("content-library", isDirectory: true)
            .appendingPathComponent("01_素材箱", isDirectory: true)
            .appendingPathComponent(category.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? "txt" : file.pathExtension
        var target = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "." + ext)
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-\(index)." + ext)
            index += 1
        }
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    public func openRuntimeScript(_ name: String) throws {
        let allowed = ["start.sh", "stop.sh", "status.sh"]
        guard allowed.contains(name) else { throw RuntimeClientError.invalidPath }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [runtimeRoot.appendingPathComponent(name).path]
        try process.run()
    }

    public func localFile(for draft: DraftManifest, asset: MediaAsset) -> URL {
        guard (try? safeRelativePath(draft.id)) != nil, !draft.id.contains("/"), (try? safeRelativePath(asset.relativePath)) != nil else { return URL(fileURLWithPath: "/invalid-media") }
        for folder in ["03_已发", "02_待发"] {
            let root = runtimeRoot.appendingPathComponent("content-library/" + folder + "/" + draft.id)
            let url = root.appendingPathComponent(asset.relativePath)
            if (try? rejectSymbolicLinks(url)) != nil, url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return URL(fileURLWithPath: "/missing-media")
    }

    public func localMaterialFile(_ material: MaterialItem) throws -> URL {
        let relative = try safeRelativePath(material.relativePath)
        let root = runtimeRoot.appendingPathComponent("content-library/01_素材箱")
        let url = root.appendingPathComponent(relative)
        try rejectSymbolicLinks(url)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw RuntimeClientError.invalidPath }
        return url
    }

    private func rejectSymbolicLinks(_ url: URL) throws {
        var component = url.standardizedFileURL
        while component.path != "/" {
            if (try? FileManager.default.attributesOfItem(atPath: component.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                throw RuntimeClientError.invalidPath
            }
            component.deleteLastPathComponent()
        }
    }

    public func call<T: Decodable & Sendable>(_ path: String, method: String = "GET", body: Data? = nil, as: T.Type) async throws -> T {
        let data = try await request(url: engineBaseURL.appendingPathComponent(path), method: method, body: body, contentType: body == nil ? nil : "application/json")
        return try decoder.decode(T.self, from: data)
    }

    public func submitJob(body: Data) async throws -> GenerationJob {
        // Tests may explicitly select the isolated engine. Production always uses n8n.
        let direct = RunConfiguration.value("XCONTENT_DIRECT_ENGINE") == "1"
        let url = direct ? engineBaseURL.appendingPathComponent("api/v1/generation-jobs") : n8nBaseURL.appendingPathComponent("webhook/x-content-app/generate")
        let data = try await request(url: url, method: "POST", body: body, contentType: "application/json")
        return try decoder.decode(GenerationJob.self, from: data)
    }

    private var receiptsRoot: URL { runtimeRoot.appendingPathComponent("content-library/.state/client-receipts") }
    public func journalReceipt(id: String, mark: PublishMark) throws {
        _ = try draftURL(id: id)
        try FileManager.default.createDirectory(at: receiptsRoot, withIntermediateDirectories: true)
        let path = receiptsRoot.appendingPathComponent(id + ".json")
        let data = try encoder.encode(mark)
        try data.write(to: path, options: .atomic)
        let handle = try FileHandle(forWritingTo: path); try handle.synchronize(); try handle.close()
    }
    public func pendingReceipts() throws -> [(String, Data)] {
        guard FileManager.default.fileExists(atPath: receiptsRoot.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: receiptsRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".acknowledged.json") }.map { ($0.deletingPathExtension().lastPathComponent, try Data(contentsOf: $0)) }
    }
    public func acknowledgeReceipt(id: String) throws {
        _ = try draftURL(id: id)
        let source = receiptsRoot.appendingPathComponent(id + ".json")
        let acknowledged = receiptsRoot.appendingPathComponent(id + ".acknowledged.json")
        if FileManager.default.fileExists(atPath: source.path) && !FileManager.default.fileExists(atPath: acknowledged.path) { try FileManager.default.moveItem(at: source, to: acknowledged) }
    }

    private func draftURL(id: String) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { throw RuntimeClientError.invalidPath }
        return engineBaseURL.appendingPathComponent("api/v1/drafts").appendingPathComponent(id)
    }

    private func safeRelativePath(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !normalized.hasPrefix("/"), !components.contains("."), !components.contains("..") else {
            throw RuntimeClientError.invalidPath
        }
        return components.joined(separator: "/")
    }

    private func probe(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private func request(url: URL, method: String, body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw RuntimeClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "本地服务请求失败"
                throw RuntimeClientError.http(status: http.statusCode, message: message)
            }
            return data
        } catch let error as RuntimeClientError {
            throw error
        } catch {
            throw RuntimeClientError.serviceUnavailable(error.localizedDescription)
        }
    }
}
