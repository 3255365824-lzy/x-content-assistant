import Foundation
import XContentAssistantCore

// Local durable state adapter only. Deliberately no network, browser, approval or auto-retry code.
func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
struct Status: Encodable {
    var executor: ReplyExecutorStatus?
    var jobs: [ReplyDispatch]
    let message = "Only queued, unexpired, non-test App approvals can be claimed. Drafts and cancelled/blocked/uncertain jobs are NOT posting authorization."
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2, args[0].hasPrefix("/") else { throw InteractionError.invalid("Usage: XReplyBridge ABSOLUTE_STORE_ROOT status|drafts|import-candidates|pulse|claim|commit-click|block|uncertain|receipt [--key value]. No approval command.") }
    let store = InteractionStore(root: URL(fileURLWithPath: args[0]))
    var options: [String: String] = [:]
    let tail = Array(args.dropFirst(2))
    guard tail.count % 2 == 0 else { throw InteractionError.invalid("参数必须成对提供") }
    for i in stride(from: 0, to: tail.count, by: 2) {
        guard tail[i].hasPrefix("--"), options[tail[i]] == nil else { throw InteractionError.invalid("无效或重复的参数") }
        options[tail[i]] = tail[i + 1]
    }
    func required(_ name: String) throws -> String {
        guard let value = options["--" + name], !value.isEmpty, value.utf8.count <= 20000 else { throw InteractionError.invalid("缺少或超长参数：\(name)") }
        return value
    }
    func observation() throws -> ReplyPageObservation {
        try JSONDecoder().decode(ReplyPageObservation.self, from: Data(required("observation").utf8))
    }
    switch args[1] {
    case "drafts":
        try output(store.load()) // Read-only; used to avoid overwriting user edits and duplicate posts.
    case "style-profile":
        try output(store.loadReplyStyle()) // Read-only derived observations; not a publication approval.
    case "import-candidates":
        let filename = try required("file")
        let file = URL(fileURLWithPath: filename).standardizedFileURL
        guard filename.hasPrefix("/"), file.path == file.resolvingSymlinksInPath().path,
              let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).fileSize,
              (1...2_000_000).contains(size),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InteractionError.invalid("候选文件必须是无符号链接、大小不超过 2 MB 的绝对路径普通文件")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= 2_000_000 else { throw InteractionError.invalid("候选文件过大") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try output(store.importPrepared(decoder.decode([PreparedReply].self, from: data)))
    case "status":
        let db = try store.load()
        try output(Status(executor: db.executor, jobs: db.items.compactMap(\.dispatch)))
    case "manual-mode":
        try output(store.loadForManualReplies())
    case "pulse":
        try store.pulse(message: required("message")); try output(["saved": true])
    case "claim", "commit-click", "block", "uncertain", "receipt":
        throw InteractionError.invalid("此版本只支持手动发送，旧网页执行命令已禁用")
    default: throw InteractionError.invalid("未知命令；本工具不能替用户确认发送，也不负责浏览器点击。")
    }
} catch {
    let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys])
    FileHandle.standardError.write(data ?? Data("{\"error\":\"local bridge failure\"}".utf8)); exit(1)
}
