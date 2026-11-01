import Foundation

/// Everything Tarn stores lives in ~/Library/Application Support/Tarn. `-TarnDataDir <path>`
/// (or TARN_DATA_DIR) points it elsewhere so test runs never touch a real profile.
enum Paths {
    static let data: URL = {
        let env = ProcessInfo.processInfo.environment["TARN_DATA_DIR"] ?? UserDefaults.standard.string(forKey: "TarnDataDir")
        let url = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tarn", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var chats: URL { dir("chats") }
    static var models: URL {
        if let m = ProcessInfo.processInfo.environment["TARN_MODELS_DIR"] {
            let u = URL(fileURLWithPath: m, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        return dir("models")
    }
    static var skills: URL { dir("skills") }
    /// Images attached to chats, downscaled to JPEG.
    static var attachments: URL { dir("attachments") }
    static var logs: URL { dir("logs") }
    static var settings: URL { data.appendingPathComponent("settings.json") }
    static var modelsState: URL { data.appendingPathComponent("models.json") }
    static var connectors: URL { data.appendingPathComponent("connectors.json") }
    static var skillsState: URL { data.appendingPathComponent("skills.json") }
    static var builtInSkills: URL? { Bundle.main.url(forResource: "Skills", withExtension: nil) }

    static var llamaServer: URL? {
        if let p = ProcessInfo.processInfo.environment["TARN_LLAMA_SERVER"] { return URL(fileURLWithPath: p) }
        return Bundle.main.url(forAuxiliaryExecutable: "llama-server")
    }

    private static func dir(_ name: String) -> URL {
        let u = data.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum JSONFile {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Atomic write: a crash mid-write leaves the previous file intact.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

/// One JSON file per chat. Chats without messages live only in memory, so empty "New chat"
/// entries don't pile up on disk.
final class ChatStore {
    private(set) var chats: [String: Chat] = [:]

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.chats, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard var chat = JSONFile.read(Chat.self, from: f), Self.validId(chat.id) else { continue }
            // A chat saved mid-answer (app quit or crashed) shouldn't show a forever-spinning reply.
            for i in chat.messages.indices where chat.messages[i].status == .streaming { chat.messages[i].status = .stopped }
            chats[chat.id] = chat
        }
    }

    static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    var summaries: [ChatSummary] {
        chats.values.filter { !$0.messages.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }.map(ChatSummary.init)
    }

    func create() -> Chat {
        let now = Date()
        let chat = Chat(id: newId(), title: "New chat", createdAt: now, updatedAt: now)
        chats[chat.id] = chat
        return chat
    }

    func save(_ chat: Chat, toDisk: Bool = true) {
        chats[chat.id] = chat
        guard toDisk, !chat.messages.isEmpty, Self.validId(chat.id) else { return }
        try? JSONFile.write(chat, to: Paths.chats.appendingPathComponent("\(chat.id).json"))
    }

    func delete(_ id: String) {
        chats[id] = nil
        guard Self.validId(id) else { return }
        try? FileManager.default.removeItem(at: Paths.chats.appendingPathComponent("\(id).json"))
    }

    func deleteAll() {
        for id in chats.keys { delete(id) }
    }

    func search(_ query: String) -> [ChatSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return summaries }
        let hits = chats.values.compactMap { c -> (Chat, Int)? in
            guard !c.messages.isEmpty else { return nil }
            if c.title.lowercased().contains(q) { return (c, 2) }
            if c.messages.contains(where: { $0.visibleText.lowercased().contains(q) }) { return (c, 1) }
            return nil
        }
        return hits.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }.map { ChatSummary($0.0) }
    }
}
