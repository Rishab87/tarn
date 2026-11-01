import Foundation

enum FolderAccess {
    static let skipDirs: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", ".next", "dist", "build", ".cache", "Library"]

    static func root(_ ctx: ToolContext) throws -> URL {
        guard let f = ctx.chat.folder else { throw ToolFailure("No folder is shared with this chat. Ask the user to choose one with the folder button.") }
        let url = URL(fileURLWithPath: f, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolFailure("The shared folder no longer exists.") }
        return url.resolvingSymlinksInPath()
    }

    /// Resolves a path inside the shared folder and rejects anything that escapes it,
    /// including through `..` or symlinks that point elsewhere.
    static func inside(_ root: URL, _ path: String, mustExist: Bool) throws -> URL {
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path.isEmpty ? "." : path)).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard target.path == rootPath || target.path.hasPrefix(rootPath + "/") else {
            throw ToolFailure("That path is outside the folder shared with Tarn.")
        }
        var probe = target
        while !FileManager.default.fileExists(atPath: probe.path) {
            if mustExist { throw ToolFailure("There’s no file or folder called “\(path)”.") }
            probe.deleteLastPathComponent()
        }
        let real = probe.resolvingSymlinksInPath().path
        guard real == rootPath || real.hasPrefix(rootPath + "/") else { throw ToolFailure("That path is outside the folder shared with Tarn.") }
        return target
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r ? "." : String(p.dropFirst(r.count + 1))
    }

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    static func size(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1 << 20 { return String(format: "%.1f KB", Double(n) / 1024) }
        if n < 1 << 30 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        return String(format: "%.1f GB", Double(n) / 1_073_741_824)
    }
}

struct ListFilesTool: Tool {
    let name = "list_files"
    let description = "List files and folders inside the shared folder (or a subfolder of it)."
    var parameters: [String: Any] {
        schema([
            "path": ["type": "string", "description": "Subfolder relative to the shared folder. Omit for the top level."],
            "depth": ["type": "integer", "description": "How many levels to go down, 1-4. Default 2."],
        ])
    }
    func label(_ args: [String: Any]) -> String { (args["path"] as? String).map { "Looked inside \($0)" } ?? "Looked at the folder" }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let root = try FolderAccess.root(ctx)
        let start = try FolderAccess.inside(root, args.optString("path") ?? "", mustExist: true)
        let depth = min(4, max(1, args.int("depth", default: 2)))
        var lines: [String] = []
        func walk(_ dir: URL, _ level: Int) {
            guard lines.count <= 400 else { return }
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let indent = String(repeating: "  ", count: level)
                if values?.isDirectory == true {
                    lines.append("\(indent)\(item.lastPathComponent)/")
                    if level + 1 < depth, !FolderAccess.skipDirs.contains(item.lastPathComponent) { walk(item, level + 1) }
                } else {
                    lines.append("\(indent)\(item.lastPathComponent)  (\(FolderAccess.size(Int64(values?.fileSize ?? 0))))")
                }
                if lines.count > 400 {
                    lines.append("… more entries not shown")
                    return
                }
            }
        }
        walk(start, 0)
        return lines.isEmpty ? "The folder is empty." : lines.joined(separator: "\n")
    }
}

struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read a text file from the shared folder. Long files can be read in parts with offset and limit (line numbers)."
    var parameters: [String: Any] {
        schema([
            "path": ["type": "string", "description": "File path relative to the shared folder."],
            "offset": ["type": "integer", "description": "First line to read (1-based). Optional."],
            "limit": ["type": "integer", "description": "Number of lines to read. Optional."],
        ], required: ["path"])
    }
    func label(_ args: [String: Any]) -> String { "Read \(args["path"] as? String ?? "a file")" }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let root = try FolderAccess.root(ctx)
        let url = try FolderAccess.inside(root, try args.string("path"), mustExist: true)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { throw ToolFailure("That’s a folder. Use list_files to see what’s inside.") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        if size > 20 << 20 { throw ToolFailure("That file is too large to read (over 20 MB).") }
        let data = try Data(contentsOf: url)
        if FolderAccess.looksBinary(data) { throw ToolFailure("That file isn’t text (it looks like an image, archive or other binary file).") }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let offset = max(1, args.int("offset", default: 1))
        let limit = max(1, args.int("limit", default: 2000))
        let slice = lines.dropFirst(offset - 1).prefix(limit)
        let body = slice.enumerated().map { "\(String(offset + $0.offset).leftPad(5))  \($0.element)" }.joined(separator: "\n")
        let more = offset - 1 + limit < lines.count ? "\n[file has \(lines.count) lines; read more with offset \(offset + limit)]" : ""
        return clip(body, 40000) + more
    }
}

struct SearchFilesTool: Tool {
    let name = "search_files"
    let description = "Find text inside files in the shared folder (case-insensitive). Returns matching lines with file names and line numbers."
    var parameters: [String: Any] {
        schema(["text": ["type": "string", "description": "Text to look for."], "path": ["type": "string", "description": "Subfolder to search in. Optional."]], required: ["text"])
    }
    func label(_ args: [String: Any]) -> String { "Searched files for “\((args["text"] as? String ?? "").prefix(60))”" }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let root = try FolderAccess.root(ctx)
        let start = try FolderAccess.inside(root, args.optString("path") ?? "", mustExist: true)
        let needle = try args.string("text").lowercased()
        var hits: [String] = []
        var scanned = 0
        let e = FileManager.default.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL, hits.count < 200, scanned < 5000 {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true {
                if FolderAccess.skipDirs.contains(url.lastPathComponent) { e?.skipDescendants() }
                continue
            }
            scanned += 1
            guard (v?.fileSize ?? 0) <= 2 << 20, let data = try? Data(contentsOf: url), !FolderAccess.looksBinary(data) else { continue }
            for (i, line) in String(decoding: data, as: UTF8.self).components(separatedBy: "\n").enumerated() where line.lowercased().contains(needle) {
                hits.append("\(FolderAccess.relative(url, to: root)):\(i + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(240))")
                if hits.count >= 200 { break }
            }
        }
        return hits.isEmpty ? "No matches." : hits.joined(separator: "\n")
    }
}

struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Create a new file or replace an existing file in the shared folder. The user approves every write."
    var parameters: [String: Any] {
        schema(["path": ["type": "string", "description": "File path relative to the shared folder."], "content": ["type": "string", "description": "The complete file contents."]], required: ["path", "content"])
    }
    func label(_ args: [String: Any]) -> String { "Wrote \(args["path"] as? String ?? "a file")" }

    func approval(_ args: [String: Any], _ ctx: ToolContext) -> ApprovalRequest? {
        let p = args["path"] as? String ?? ""
        let exists = ctx.chat.folder.map { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).appendingPathComponent(p).path) } ?? false
        return ApprovalRequest(title: exists ? "Replace \(p)?" : "Create \(p)?", detail: clip(args["content"] as? String ?? "", 4000))
    }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let root = try FolderAccess.root(ctx)
        let url = try FolderAccess.inside(root, try args.string("path"), mustExist: false)
        let content = args["content"] as? String ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return "Saved \(FolderAccess.relative(url, to: root)) (\(FolderAccess.size(Int64(content.utf8.count))))."
    }
}

struct EditFileTool: Tool {
    let name = "edit_file"
    let description = "Change part of a text file in the shared folder by replacing exact text. old_text must appear exactly once."
    var parameters: [String: Any] {
        schema([
            "path": ["type": "string"],
            "old_text": ["type": "string", "description": "Exact text to replace, copied from the file."],
            "new_text": ["type": "string", "description": "Text to put in its place."],
        ], required: ["path", "old_text", "new_text"])
    }
    func label(_ args: [String: Any]) -> String { "Edited \(args["path"] as? String ?? "a file")" }

    func approval(_ args: [String: Any], _ ctx: ToolContext) -> ApprovalRequest? {
        ApprovalRequest(title: "Edit \(args["path"] as? String ?? "")?",
                        detail: "Replace:\n\(clip(args["old_text"] as? String ?? "", 1500))\n\nWith:\n\(clip(args["new_text"] as? String ?? "", 1500))")
    }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let root = try FolderAccess.root(ctx)
        let url = try FolderAccess.inside(root, try args.string("path"), mustExist: true)
        let old = try args.string("old_text")
        let new = args["new_text"] as? String ?? ""
        let text = try String(contentsOf: url, encoding: .utf8)
        let count = text.components(separatedBy: old).count - 1
        if count == 0 { throw ToolFailure("old_text wasn’t found in the file. Read the file again and copy the text exactly.") }
        if count > 1 { throw ToolFailure("old_text appears \(count) times. Include more surrounding text so it’s unique.") }
        try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: url, options: .atomic)
        return "Updated \(FolderAccess.relative(url, to: root))."
    }
}

struct RunCommandTool: Tool {
    let name = "run_command"
    let description = "Run a terminal command (zsh) inside the shared folder, e.g. to convert files, run scripts or use installed tools. The user approves every command. Avoid long-running servers."
    var parameters: [String: Any] {
        schema([
            "command": ["type": "string", "description": "The command line to run."],
            "timeout_seconds": ["type": "integer", "description": "Stop the command after this many seconds (max 600, default 120)."],
        ], required: ["command"])
    }
    func label(_ args: [String: Any]) -> String { "Ran `\((args["command"] as? String ?? "").prefix(80))`" }
    func approval(_ args: [String: Any], _ ctx: ToolContext) -> ApprovalRequest? {
        ApprovalRequest(title: "Run this command in your folder?", detail: args["command"] as? String ?? "")
    }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let root = try FolderAccess.root(ctx)
        let command = try args.string("command")
        let timeout = Double(min(600, max(1, args.int("timeout_seconds", default: 120))))
        let env = await Task.detached { ShellEnv.environment() }.value
        return try await withTaskCancellationHandler {
            try await Self.execute(command, in: root, env: env, timeout: timeout)
        } onCancel: {}
    }

    private static func execute(_ command: String, in dir: URL, env: [String: String], timeout: Double) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }
        try p.run()
        // Own process group, so stopping it also stops anything it started.
        setpgid(p.processIdentifier, p.processIdentifier)
        let pid = p.processIdentifier
        var note = ""
        let start = Date()
        while p.isRunning {
            if Task.isCancelled {
                kill(-pid, SIGKILL); kill(pid, SIGKILL)
                note = "\n[stopped by the user]"
                break
            }
            if Date().timeIntervalSince(start) > timeout {
                kill(-pid, SIGKILL); kill(pid, SIGKILL)
                note = "\n[stopped after \(Int(timeout)) seconds]"
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let out = buffer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(clip(out.isEmpty ? "(no output)" : out, 16000))\(note)\n\n[exit code \(p.terminationStatus)]"
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) {
        lock.lock()
        data.append(d)
        if data.count > 400_000 { data = data.suffix(200_000) }
        lock.unlock()
    }
    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
