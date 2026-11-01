import Foundation
import ZIPFoundation

// A backup is a plain .zip anyone can open:
//   manifest.json      format and version
//   settings.json      preferences
//   chats/<id>.json    one file per conversation
//   skills/<name>/…    skills the user added
//   connectors.json    connector settings
// AI models aren't included: they're large, and Tarn downloads the right one for each Mac.

enum Backup {
    static let format = "tarn-backup"
    static let version = 1
    static let maxZipBytes: Int64 = 1 << 30
    static let maxUnpacked: Int64 = 2 << 30
    static let maxFiles = 50_000

    struct Manifest: Codable {
        var format: String
        var version: Int
        var appVersion: String?
        var createdAt: Date?
        var chats: Int?
    }

    struct Contents {
        var settings: AppSettings?
        var chats: [Chat] = []
        var skipped = 0
        var skillFiles: [(path: String, data: Data)] = []
        var connectors: [ConnectorConfig] = []
    }

    static func export(to dest: URL, chats: [Chat], settings: AppSettings, connectors: [ConnectorConfig]) throws {
        try? FileManager.default.removeItem(at: dest)
        let archive = try Archive(url: dest, accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        let manifest = Manifest(format: format, version: version, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, createdAt: Date(), chats: chats.count)
        try add("manifest.json", JSONFile.encoder.encode(manifest))
        var portable = settings
        portable.onboarded = false
        try add("settings.json", JSONFile.encoder.encode(portable))
        for c in chats where !c.messages.isEmpty { try add("chats/\(c.id).json", JSONFile.encoder.encode(c)) }
        try add("connectors.json", JSONFile.encoder.encode(connectors))
        let root = Paths.skills
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let u = e.nextObject() as? URL {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let d = try? Data(contentsOf: u) else { continue }
                try add("skills/" + FolderAccess.relative(u, to: root), d)
            }
        }
    }

    static func read(_ file: URL) throws -> Contents {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        if size > maxZipBytes { throw ToolFailure("That file is too large to be a Tarn backup.") }
        let archive: Archive
        do { archive = try Archive(url: file, accessMode: .read) } catch { throw ToolFailure("That file isn’t a valid zip file.") }
        var files: [String: Entry] = [:]
        var total: Int64 = 0
        for entry in archive where entry.type == .file {
            if entry.path.hasPrefix("__MACOSX/") { continue }
            total += Int64(entry.uncompressedSize)
            if files.count >= maxFiles || total > maxUnpacked { throw ToolFailure("That backup is too large to import.") }
            files[entry.path] = entry
        }
        // Backups re-zipped by Finder may sit inside one top-level folder.
        var prefix = ""
        if files["manifest.json"] == nil, let nested = files.keys.first(where: { $0.hasSuffix("/manifest.json") && $0.filter { $0 == "/" }.count == 1 }) {
            prefix = String(nested.dropLast("manifest.json".count))
        }
        func data(_ path: String) -> Data? {
            guard let e = files[prefix + path], e.uncompressedSize < 200 << 20 else { return nil }
            var d = Data()
            _ = try? archive.extract(e) { d.append($0) }
            return d
        }
        guard let m = data("manifest.json"), let manifest = try? JSONFile.decoder.decode(Manifest.self, from: m), manifest.format == format else {
            throw ToolFailure("That zip isn’t a Tarn backup.")
        }
        guard manifest.version <= version else { throw ToolFailure("This backup was made by a newer version of Tarn. Update Tarn, then import it again.") }

        var out = Contents()
        out.settings = data("settings.json").flatMap { try? JSONFile.decoder.decode(AppSettings.self, from: $0) }
        for path in files.keys where path.hasPrefix(prefix + "chats/") && path.hasSuffix(".json") {
            let rel = String(path.dropFirst(prefix.count))
            let id = String(rel.dropFirst("chats/".count).dropLast(".json".count))
            guard ChatStore.validId(id), let d = data(rel), var chat = try? JSONFile.decoder.decode(Chat.self, from: d), chat.id == id else {
                out.skipped += 1
                continue
            }
            for i in chat.messages.indices where chat.messages[i].status == .streaming { chat.messages[i].status = .stopped }
            out.chats.append(chat)
        }
        for path in files.keys where path.hasPrefix(prefix + "skills/") {
            let rel = String(path.dropFirst(prefix.count + "skills/".count))
            if let d = data("skills/" + rel) { out.skillFiles.append((rel, d)) }
        }
        out.connectors = data("connectors.json").flatMap { try? JSONFile.decoder.decode([ConnectorConfig].self, from: $0) } ?? []
        return out
    }

    /// Writes skill files from a backup, refusing any path that escapes the skills folder.
    static func restoreSkills(_ files: [(path: String, data: Data)]) -> Int {
        let root = Paths.skills.standardizedFileURL
        var names = Set<String>()
        for f in files {
            let parts = f.path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = Skills.slug(String(parts[0]))
            guard !name.isEmpty else { continue }
            let skillDir = root.appendingPathComponent(name, isDirectory: true)
            let target = skillDir.appendingPathComponent(String(parts[1])).standardizedFileURL
            guard target.path.hasPrefix(skillDir.path + "/") else { continue }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? f.data.write(to: target)) != nil { names.insert(name) }
        }
        return names.count
    }
}
