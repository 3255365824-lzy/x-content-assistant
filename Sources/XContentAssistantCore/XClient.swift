import Foundation
import Security

public enum XClientError: LocalizedError, Sendable {
    case invalidURL
    case authenticationRequired
    case http(status: Int, message: String)
    case ambiguous(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "X API 地址无效"
        case .authenticationRequired: return "尚未连接 X 账号"
        case .http(let status, let message):
            if message.localizedCaseInsensitiveContains("credit") || message.localizedCaseInsensitiveContains("balance") || message.localizedCaseInsensitiveContains("insufficient") {
                return "X API 余额不足，请前往 Developer Console 充值"
            }
            switch status {
            case 401: return "X 401：登录令牌已失效，请重新连接 X 账号"
            case 403: return "X 403：请检查应用权限或账号限制"
            case 429: return "X 429：已触发限流，请稍后再试"
            case 402: return "X 402：API 余额不足，请前往 Developer Console 充值"
            default: return "X API 错误 \(status)：\(message)"
            }
        case .ambiguous(let message): return message
        }
    }
}

public struct XTokenResponse: Codable, Sendable {
    public var tokenType: String?
    public var expiresIn: Int?
    public var accessToken: String
    public var scope: String?
    public var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case accessToken = "access_token"
        case scope
        case refreshToken = "refresh_token"
    }
}

private struct XUserResponse: Codable, Sendable {
    struct User: Codable, Sendable {
        var id: String
        var username: String
    }
    var data: User
}

public protocol TokenStore: Sendable {
    func save(_ value: String, key: String) throws
    func load(key: String) -> String?
    func delete(key: String)
}
public final class KeychainStore: TokenStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.longzhengyang.x-content-assistant") {
        self.service = service
    }

    public func save(_ value: String, key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        var item = query
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil) }
    }

    public func load(key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

public final class XAPIClient: @unchecked Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let apiBaseURL: URL
    private let authorizationBaseURL: URL

    public init(session: URLSession = .shared, apiBaseURL: URL = URL(string: "https://api.x.com")!, authorizationBaseURL: URL = URL(string: "https://x.com")!) {
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.authorizationBaseURL = authorizationBaseURL
    }

    public func authorizationURL(clientID: String, redirectURI: String, pkce: PKCEPair) throws -> URL {
        guard var components = URLComponents(url: authorizationBaseURL.appendingPathComponent("i/oauth2/authorize"), resolvingAgainstBaseURL: false) else { throw XClientError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "tweet.read users.read tweet.write media.write offline.access"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else { throw XClientError.invalidURL }
        return url
    }

    public func exchangeCode(clientID: String, code: String, redirectURI: String, verifier: String) async throws -> XTokenResponse {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("2/oauth2/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("2/oauth2/token"))
        request.httpMethod = "POST"
        request.httpBody = components.queryItems?.map { Self.form($0.name) + "=" + Self.form($0.value ?? "") }.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data = try await send(request)
        return try decoder.decode(XTokenResponse.self, from: data)
    }

    public func refresh(clientID: String, refreshToken: String) async throws -> XTokenResponse {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("2/oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "refresh_token=\(Self.form(refreshToken))&grant_type=refresh_token&client_id=\(Self.form(clientID))".data(using: .utf8)
        return try decoder.decode(XTokenResponse.self, from: try await send(request))
    }

    public func uploadPNG(_ data: Data, accessToken: String) async throws -> String {
        let payload: [String: String] = ["media": data.base64EncodedString(), "media_category": "tweet_image"]
        let result = try await apiJSON(path: "/2/media/upload", method: "POST", body: try encoder.encode(payload), accessToken: accessToken)
        guard let value = result["data"] as? [String: Any], let id = value["id"] as? String else { throw XClientError.ambiguous("X 返回了无媒体 ID 的结果") }
        return id
    }

    public func currentUser(accessToken: String) async throws -> XAccount {
        let result = try await apiJSON(path: "/2/users/me?user.fields=username", method: "GET", body: nil, accessToken: accessToken)
        guard let data = try? JSONSerialization.data(withJSONObject: result), let decoded = try? decoder.decode(XUserResponse.self, from: data) else {
            throw XClientError.ambiguous("X 返回了无法识别的账号信息")
        }
        return XAccount(username: decoded.data.username, userID: decoded.data.id)
    }

    /// Read-only newest page from followed accounts, never the algorithmic For You feed.
    public func followingPosts(accountID: String, accessToken: String) async throws -> [InteractionPost] {
        guard InteractionRules.validID(accountID) else { throw XClientError.invalidURL }
        var components = URLComponents()
        components.path = "/2/users/\(accountID)/timelines/reverse_chronological"
        components.queryItems = [URLQueryItem(name: "max_results", value: "25"), URLQueryItem(name: "exclude", value: "retweets,replies"),
            URLQueryItem(name: "tweet.fields", value: "author_id,created_at,note_tweet"), URLQueryItem(name: "expansions", value: "author_id"), URLQueryItem(name: "user.fields", value: "username")]
        let result = try await apiJSON(path: components.string!, method: "GET", body: nil, accessToken: accessToken)
        guard result["errors"] == nil else { throw InteractionError.invalid("X 时间线响应不完整，请检查读取权限；未更新本地列表") }
        guard let rows = result["data"] as? [[String: Any]] else {
            if (result["meta"] as? [String: Any])?["result_count"] as? Int == 0 { return [] }
            throw InteractionError.invalid("X 时间线返回格式无法识别")
        }
        let users = (result["includes"] as? [String: Any])?["users"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String, InteractionRules.validID(id), let author = row["author_id"] as? String, author != accountID,
                  let text = (row["note_tweet"] as? [String: Any])?["text"] as? String ?? row["text"] as? String,
                  (8...12000).contains(text.count) else { return nil }
            let username = users.first(where: { $0["id"] as? String == author })?["username"] as? String ?? "作者未提供"
            return InteractionPost(id: id, text: text, username: username, authorID: author, createdAt: row["created_at"] as? String,
                category: InteractionRules.category(text), origin: "关注时间线", sourceAccountID: accountID)
        }
    }

    public func createPost(text: String, mediaID: String?, madeWithAI: Bool, accessToken: String) async throws -> (id: String, text: String) {
        var payload: [String: Any] = ["text": text]
        if let mediaID { payload["media"] = ["media_ids": [mediaID]] }
        if madeWithAI { payload["made_with_ai"] = true }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let result = try await apiJSON(path: "/2/tweets", method: "POST", body: body, accessToken: accessToken)
        guard let value = result["data"] as? [String: Any], let id = value["id"] as? String else { throw XClientError.ambiguous("X 返回了无帖子 ID 的结果") }
        return (id, value["text"] as? String ?? text)
    }

    private func apiJSON(path: String, method: String, body: Data?, accessToken: String) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: apiBaseURL) else { throw XClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw XClientError.ambiguous("X 返回了无法识别的 JSON") }
        return json
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            var bounded = request
            bounded.timeoutInterval = 60
            let (data, response) = try await session.data(for: bounded)
            guard let http = response as? HTTPURLResponse else { throw XClientError.ambiguous("无法确认 X API 的响应") }
            guard (200..<300).contains(http.statusCode) else {
                // Only retain a non-sensitive classification, not a raw upstream body.
                let raw = String(data: data, encoding: .utf8) ?? ""
                let message = raw.localizedCaseInsensitiveContains("creditsdepleted") || raw.localizedCaseInsensitiveContains("insufficient balance") ? "insufficient credits" : "请求未被接受，请检查 Developer Console"
                if http.statusCode >= 500 && request.url?.path == "/2/tweets" {
                    throw XClientError.ambiguous("X 服务错误，不能确定帖子是否已创建，请核对后处理")
                }
                throw XClientError.http(status: http.statusCode, message: message)
            }
            return data
        } catch let error as XClientError {
            throw error
        } catch {
            throw XClientError.ambiguous("X API 请求结果不确定：\(error.localizedDescription)")
        }
    }

    private static func form(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }
}
