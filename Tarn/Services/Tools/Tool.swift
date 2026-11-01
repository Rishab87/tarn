import Foundation

struct ToolContext {
    var chat: Chat
}

struct ToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Something the model can call. Tools that change things return an ApprovalRequest so the
/// user confirms first.
protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON schema of the arguments.
    var parameters: [String: Any] { get }
    func label(_ args: [String: Any]) -> String
    func approval(_ args: [String: Any], _ ctx: ToolContext) -> ApprovalRequest?
    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String
}

extension Tool {
    func approval(_ args: [String: Any], _ ctx: ToolContext) -> ApprovalRequest? { nil }

    var definition: [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
}

func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String {
        if let s = self[key] as? String, !s.isEmpty { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        throw ToolFailure("Missing or invalid “\(key)” argument.")
    }

    func optString(_ key: String) -> String? {
        if let s = self[key] as? String, !s.isEmpty { return s }
        return nil
    }

    func int(_ key: String, default value: Int) -> Int {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String, let n = Int(s) { return n }
        return value
    }
}

/// Keeps the start and end of long output so the model sees both.
func clip(_ text: String, _ max: Int = 16000) -> String {
    guard text.count > max else { return text }
    let head = Int(Double(max) * 0.7)
    return "\(text.prefix(head))\n\n[… \(text.count - max) characters cut …]\n\n\(text.suffix(max - head))"
}

/// Apps opened from Finder get a minimal PATH, so tools installed with Homebrew, nvm or uv
/// aren't found. Ask the user's login shell for its PATH once.
enum ShellEnv {
    nonisolated(unsafe) private static var cached: [String: String]?
    private static let lock = NSLock()

    static func environment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '__TARN__%s__TARN__' \"$PATH\""]
        var penv = env
        penv["TERM"] = "dumb"
        p.environment = penv
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var path: String?
        if (try? p.run()) != nil {
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            let s = String(data: data, encoding: .utf8) ?? ""
            if let r = s.range(of: "__TARN__"), let e = s.range(of: "__TARN__", range: r.upperBound..<s.endIndex) {
                path = String(s[r.upperBound..<e.lowerBound])
            }
        }
        let fallback = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = path.flatMap { $0.contains("/") ? $0 : nil } ?? (env["PATH"].map { $0 + ":" } ?? "") + fallback.joined(separator: ":")
        cached = env
        return env
    }
}
