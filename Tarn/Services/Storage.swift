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
    /// Sidebar folders (`ChatGroup`).
    static var groups: URL { data.appendingPathComponent("groups.json") }
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
/// entries don't pile up on disk. Sidebar folders live in one groups.json.
final class ChatStore {
    private(set) var chats: [String: Chat] = [:]
    /// Sidebar folders, sorted by name.
    private(set) var groups: [ChatGroup] = []
    private let dir: URL
    private let groupsFile: URL

    /// Tests pass scratch locations; the app uses Tarn's data folder.
    init(dir: URL = Paths.chats, groupsFile: URL = Paths.groups) {
        self.dir = dir
        self.groupsFile = groupsFile
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard var chat = JSONFile.read(Chat.self, from: f), Self.validId(chat.id) else { continue }
            // A chat saved mid-answer (app quit or crashed) shouldn't show a forever-spinning reply.
            for i in chat.messages.indices where chat.messages[i].status == .streaming { chat.messages[i].status = .stopped }
            chats[chat.id] = chat
        }
        groups = Self.byName(JSONFile.read([ChatGroup].self, from: groupsFile) ?? [])
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
        try? JSONFile.write(chat, to: dir.appendingPathComponent("\(chat.id).json"))
    }

    func delete(_ id: String) {
        chats[id] = nil
        guard Self.validId(id) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
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

    // MARK: Folders

    @discardableResult
    func createGroup(_ name: String) -> ChatGroup? {
        let clean = ChatGroup.cleanName(name)
        guard !clean.isEmpty else { return nil }
        let group = ChatGroup(id: newId(), name: clean, createdAt: Date())
        groups.append(group)
        saveGroups()
        return group
    }

    func renameGroup(_ id: String, _ name: String) {
        let clean = ChatGroup.cleanName(name)
        guard !clean.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = clean
        saveGroups()
    }

    func setGroupCollapsed(_ id: String, _ collapsed: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == id }), groups[i].collapsed != collapsed else { return }
        groups[i].collapsed = collapsed
        saveGroups()
    }

    /// Deletes only the folder: its chats go back to the main list.
    func deleteGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        saveGroups()
        for var chat in chats.values where chat.groupId == id {
            chat.groupId = nil
            save(chat)
        }
    }

    /// Files a chat in a folder, or takes it out with nil. False when nothing changed
    /// (unknown chat or folder, or already there).
    @discardableResult
    func move(_ chatId: String, to groupId: String?) -> Bool {
        guard var chat = chats[chatId], chat.groupId != groupId,
              groupId == nil || groups.contains(where: { $0.id == groupId }) else { return false }
        chat.groupId = groupId
        save(chat)
        return true
    }

    /// Folders from a backup. Merging keeps the folders already here as they are.
    func importGroups(_ incoming: [ChatGroup], replace: Bool) {
        if replace { groups = [] }
        for g in incoming where !groups.contains(where: { $0.id == g.id }) { groups.append(g) }
        saveGroups()
    }

    private func saveGroups() {
        groups = Self.byName(groups)
        try? JSONFile.write(groups, to: groupsFile)
    }

    private static func byName(_ groups: [ChatGroup]) -> [ChatGroup] {
        groups.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }
}
