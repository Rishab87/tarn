import Foundation
import ZIPFoundation

// Skills follow the open Agent Skills layout: a folder with a SKILL.md whose front matter has
// `name` and `description`, plus optional reference files. The model sees each enabled skill's
// description and loads the full instructions only when a request needs them.

enum Skills {
    static let maxBytes: Int64 = 20 << 20

    static func parseFrontMatter(_ md: String) -> (meta: [String: String], body: String) {
        guard let m = md.firstMatch(of: /^\u{FEFF}?---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/) else { return ([:], md) }
        var meta: [String: String] = [:]
        let lines = m.1.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        var i = 0
        while i < lines.count {
            if let kv = lines[i].firstMatch(of: /^([A-Za-z_][\w-]*):\s*(.*)$/) {
                var value = String(kv.2).trimmingCharacters(in: .whitespaces)
                if [">", "|", ">-", "|-"].contains(value) {
                    var parts: [String] = []
                    while i + 1 < lines.count, lines[i + 1].first?.isWhitespace == true {
                        i += 1
                        parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    }
                    value = parts.joined(separator: value.hasPrefix(">") ? " " : "\n")
                }
                if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
                meta[String(kv.1)] = value
            }
            i += 1
        }
        return (meta, String(m.2))
    }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased().replacing(/[^a-z0-9]+/, with: "-")
        return String(lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
    }

    private static func read(_ dir: URL, builtIn: Bool, disabled: Set<String>) -> Skill? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        let meta = parseFrontMatter(text).meta
        let name = slug(meta["name"] ?? dir.lastPathComponent)
        let description = String((meta["description"] ?? "").prefix(1024))
        guard !name.isEmpty, !description.isEmpty else { return nil }
        return Skill(name: name, description: description, builtIn: builtIn, enabled: !disabled.contains(name), dir: dir)
    }

    private static var disabled: Set<String> {
        Set(JSONFile.read([String].self, from: Paths.skillsState) ?? [])
    }

    static func list() -> [Skill] {
        let off = disabled
        var out: [String: Skill] = [:]
        for (root, builtIn) in [(Paths.builtInSkills, true), (Paths.skills as URL?, false)] {
            guard let root, let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for d in dirs where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if let s = read(d, builtIn: builtIn, disabled: off) { out[s.name] = s } // user skills override built-ins
            }
        }
        return out.values.sorted { $0.builtIn != $1.builtIn ? $0.builtIn : $0.name < $1.name }
    }

    static func enabled() -> [Skill] { list().filter(\.enabled) }

    static func setEnabled(_ name: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(name) } else { off.insert(name) }
        try? JSONFile.write(Array(off).sorted(), to: Paths.skillsState)
    }

    static func remove(_ name: String) throws {
        guard let s = list().first(where: { $0.name == name }), !s.builtIn else { throw ToolFailure("Built-in skills can be switched off but not removed.") }
        try FileManager.default.removeItem(at: s.dir)
    }

    static func create(name: String, description: String, instructions: String) throws {
        let n = slug(name)
        let d = description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !n.isEmpty else { throw ToolFailure("Give the skill a name.") }
        guard !d.isEmpty else { throw ToolFailure("Describe when Tarn should use this skill.") }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolFailure("Write the instructions Tarn should follow.") }
        let dir = Paths.skills.appendingPathComponent(n, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let quoted = d.replacingOccurrences(of: "\"", with: "'")
        try Data("---\nname: \(n)\ndescription: \"\(quoted)\"\n---\n\n\(instructions.trimmingCharacters(in: .whitespacesAndNewlines))\n".utf8)
            .write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)
    }

    /// Copies a skill folder (the one containing SKILL.md) into Tarn.
    static func importFolder(_ src: URL) throws {
        guard let s = read(src, builtIn: false, disabled: []) else { throw ToolFailure("That folder doesn’t contain a SKILL.md with a name and description.") }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: src, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        while let u = e?.nextObject() as? URL {
            let v = try u.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if v.isSymbolicLink == true { throw ToolFailure("Skills can’t contain links to other files.") }
            total += Int64(v.fileSize ?? 0)
            if total > maxBytes { throw ToolFailure("That skill is larger than 20 MB.") }
        }
        let dest = Paths.skills.appendingPathComponent(s.name, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// Unpacks a skill .zip safely: nothing outside the skill folder, size-capped.
    static func importZip(_ file: URL) throws {
        let archive = try Archive(url: file, accessMode: .read)
        var total: Int64 = 0
        var entries: [Entry] = []
        for entry in archive where entry.type == .file {
            if entry.path.hasPrefix("__MACOSX/") || (entry.path as NSString).lastPathComponent.hasPrefix("._") { continue }
            total += Int64(entry.uncompressedSize)
            if total > maxBytes { throw ToolFailure("That skill is larger than 20 MB.") }
            entries.append(entry)
        }
        guard let skillMd = entries.map(\.path).filter({ $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }).min(by: { $0.count < $1.count }) else {
            throw ToolFailure("That zip doesn’t contain a SKILL.md.")
        }
        let prefix = String(skillMd.dropLast("SKILL.md".count))
        var mdData = Data()
        _ = try archive.extract(entries.first { $0.path == skillMd }!) { mdData.append($0) }
        let meta = parseFrontMatter(String(decoding: mdData, as: UTF8.self)).meta
        let name = slug(meta["name"] ?? (prefix.isEmpty ? file.deletingPathExtension().lastPathComponent : String(prefix.dropLast())))
        guard !name.isEmpty, meta["description"]?.isEmpty == false else { throw ToolFailure("The SKILL.md needs a name and a description.") }
        let dest = Paths.skills.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for entry in entries where entry.path.hasPrefix(prefix) {
            let target = dest.appendingPathComponent(String(entry.path.dropFirst(prefix.count))).standardizedFileURL
            guard target.path.hasPrefix(dest.standardizedFileURL.path + "/") else { continue } // zip-slip guard
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            try data.write(to: target)
        }
    }
}

struct UseSkillTool: Tool {
    let name = "use_skill"
    let description = "Load the full instructions of one of your skills before doing a task it covers. Optionally read one of the skill’s extra files."
    var parameters: [String: Any] {
        schema([
            "name": ["type": "string", "description": "Skill name from the list of available skills."],
            "file": ["type": "string", "description": "Optional extra file inside the skill, e.g. reference.md"],
        ], required: ["name"])
    }
    func label(_ args: [String: Any]) -> String { "Used the \(args["name"] as? String ?? "") skill" }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let n = Skills.slug(try args.string("name"))
        guard let s = Skills.enabled().first(where: { $0.name == n }) else { throw ToolFailure("There’s no enabled skill called “\(n)”.") }
        if let file = args.optString("file") {
            let target = s.dir.appendingPathComponent(file).standardizedFileURL
            guard target.path.hasPrefix(s.dir.standardizedFileURL.path + "/"), let text = try? String(contentsOf: target, encoding: .utf8) else {
                throw ToolFailure("That file isn’t part of the skill.")
            }
            return clip(text)
        }
        let body = Skills.parseFrontMatter((try? String(contentsOf: s.dir.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "").body
        let extras = (FileManager.default.enumerator(at: s.dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent != "SKILL.md" && !$0.hasDirectoryPath }
            .map { FolderAccess.relative($0, to: s.dir) }
        return clip(body.trimmingCharacters(in: .whitespacesAndNewlines)) + (extras.isEmpty ? "" : "\n\nExtra files in this skill: \(extras.joined(separator: ", "))")
    }
}
