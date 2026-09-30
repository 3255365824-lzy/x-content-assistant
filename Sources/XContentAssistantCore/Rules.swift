import Foundation
import CryptoKit
import Security

public enum XTextRules {
    public static let maximumWeightedLength = 280
    public static let urlWeightedLength = 23
    public static let basePostEstimateUSD = 0.015
    public static let postWithURLEstimateUSD = 0.200

    public static func containsURL(_ text: String) -> Bool {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return (detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).contains { ["http", "https"].contains($0.url?.scheme ?? "") }
    }

    public static func weightedLength(_ value: String) -> Int {
        let normalized = value.precomposedStringWithCanonicalMapping
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) ?? []
        var text = normalized
        var length = 0
        for match in matches.reversed() where match.url?.scheme == "http" || match.url?.scheme == "https" {
            if let range = Range(match.range, in: text) { text.removeSubrange(range); length += urlWeightedLength }
        }
        return length + text.reduce(0) { total, character in
            let scalars = character.unicodeScalars
            if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value == 0x20E3 }) { return total + 2 }
            return total + scalars.reduce(0) { result, scalar in
                let v = scalar.value
                return result + ((v <= 0x10FF || (0x2000...0x200D).contains(v) || (0x2010...0x201F).contains(v) || (0x2032...0x2037).contains(v)) ? 1 : 2)
            }
        }
    }

    public static func composedText(postText: String, sourceURL: String?, includeSourceURL: Bool) -> String {
        let trimmed = postText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard includeSourceURL, let sourceURL, !sourceURL.isEmpty else { return trimmed }
        return trimmed + "\n" + sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validate(postText: String, sourceURL: String?, includeSourceURL: Bool) -> (valid: Bool, weightedLength: Int, message: String) {
        let trimmedPost = postText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = composedText(postText: trimmedPost, sourceURL: sourceURL, includeSourceURL: includeSourceURL)
        guard !trimmedPost.isEmpty else { return (false, 0, "文案不能为空") }
        let url = URLComponents(string: sourceURL ?? "")
        guard !includeSourceURL || (["http", "https"].contains(url?.scheme ?? "") && !(url?.host ?? "").isEmpty && url?.user == nil) else {
            return (false, weightedLength(text), "原文链接必须是 http 或 https")
        }
        let length = weightedLength(text)
        guard length <= maximumWeightedLength else {
            return (false, length, "文案超过 X 的长度限制")
        }
        return (true, length, "可以发布")
    }
}

public enum ScheduleRules {
    public static func normalizedTimes(_ times: [String]) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return Array(Set(times.compactMap { value in
            guard value.range(of: "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { return nil }
            return value
        })).sorted()
    }

    public static func slotKey(for date: Date, config: ScheduleConfig, calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        guard config.enabled else { return nil }
        var localCalendar = calendar
        if let timeZone = TimeZone(identifier: config.timezone) { localCalendar.timeZone = timeZone }
        let formatter = DateFormatter()
        formatter.calendar = localCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = localCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let current = formatter.string(from: date)
        let time = String(current.dropFirst(11))
        return normalizedTimes(config.times).contains(time) ? current : nil
    }

    public static func nextRun(after date: Date, config: ScheduleConfig, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard config.enabled, !config.times.isEmpty else { return nil }
        var localCalendar = calendar
        if let timeZone = TimeZone(identifier: config.timezone) { localCalendar.timeZone = timeZone }
        let validTimes = normalizedTimes(config.times)
        let components = localCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let dayStart = localCalendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: 0, minute: 0)) else { return nil }
        for dayOffset in 0...2 {
            guard let day = localCalendar.date(byAdding: .day, value: dayOffset, to: dayStart) else { continue }
            for time in validTimes {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, let candidate = localCalendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) else { continue }
                if candidate > date { return candidate }
            }
        }
        return nil
    }
}

public enum DraftStateRules {
    public static func canBeginPublishing(_ status: DraftStatus) -> Bool {
        status == .queued || status == .failed
    }

    public static func isTerminal(_ status: DraftStatus) -> Bool {
        status == .published
    }
}

public enum TextHasher {
    public static func sha256Data(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct PKCEPair: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init(verifier: String, challenge: String, state: String) {
        self.verifier = verifier
        self.challenge = challenge
        self.state = state
    }

    public static func make() -> PKCEPair {
        let verifier = randomURLSafeString(byteCount: 48)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PKCEPair(verifier: verifier, challenge: challenge, state: randomURLSafeString(byteCount: 24))
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
