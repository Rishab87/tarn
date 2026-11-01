import Foundation

// Connectors speak the Model Context Protocol (JSON-RPC 2.0). Two transports are supported:
// a local program over stdin/stdout, and a remote server over Streamable HTTP.

protocol MCPTransport: AnyObject {
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    func notify(_ method: String, _ params: [String: Any]) async throws
    func close()
}

struct MCPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextId = 1
    private let lock = NSLock()

    init(command: String, args: [String], env: [String: String]) throws {
        var environment = ShellEnv.environment()
        for (k, v) in env { environment[k] = v }
        // Resolve the command through the user's PATH (npx, uvx, docker…).
        let resolved = command.contains("/") ? command : Self.which(command, path: environment["PATH"] ?? "")
        guard let resolved else { throw MCPError(message: "not found: \(command)") }
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = args
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receive(h.availableData) }
        process.terminationHandler = { [weak self] _ in self?.failAll(MCPError(message: "The connector program exited.")) }
        try process.run()
    }

    static func which(_ cmd: String, path: String) -> String? {
        for dir in path.split(separator: ":") {
            let p = "\(dir)/\(cmd)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private func receive(_ data: Data) {
        if data.isEmpty { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer = buffer[(nl + 1)...]
        }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = msg["method"] as? String, let id = msg["id"] {
            // A request from the server. Answer pings; decline everything else politely.
            let reply: [String: Any] = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Tarn doesn’t support \(method)."]]
            try? write(reply)
            return
        }
        guard let id = msg["id"] as? Int else { return }
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = msg["error"] as? [String: Any] {
            c?.resume(throwing: MCPError(message: err["message"] as? String ?? "The connector reported an error."))
        } else {
            c?.resume(returning: msg["result"] as? [String: Any] ?? [:])
        }
    }

    private func write(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let all = pending
        pending = [:]
        lock.unlock()
        for c in all.values { c.resume(throwing: error) }
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            let id = nextId
            nextId += 1
            pending[id] = c
            lock.unlock()
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                lock.lock()
                pending[id] = nil
                lock.unlock()
                c.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) async throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        failAll(MCPError(message: "Disconnected."))
    }
}

final class HTTPTransport: MCPTransport, @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private var sessionId: String?
    private var protocolVersion: String?
    private var nextId = 1

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    func setProtocolVersion(_ v: String) { protocolVersion = v }

    private func post(_ body: [String: Any]) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, res) = try await URLSession.shared.bytes(for: req)
        guard let http = res as? HTTPURLResponse else { throw MCPError(message: "No response from the connector.") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = sid }
        if http.statusCode == 401 || http.statusCode == 403 { throw MCPError(message: "401 unauthorized") }
        guard (200..<300).contains(http.statusCode) else { throw MCPError(message: "The connector answered \(http.statusCode).") }
        return (bytes, http)
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let (bytes, http) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            var data = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data:") {
                    data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if let msg = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] {
                        data = ""
                        if (msg["id"] as? Int) == id { return try Self.unwrap(msg) }
                    }
                }
            }
            throw MCPError(message: "The connector closed the stream without answering.")
        }
        var body = Data()
        for try await b in bytes { body.append(b) }
        guard let msg = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw MCPError(message: "The connector sent an unreadable answer.") }
        return try Self.unwrap(msg)
    }

    private static func unwrap(_ msg: [String: Any]) throws -> [String: Any] {
        if let err = msg["error"] as? [String: Any] { throw MCPError(message: err["message"] as? String ?? "The connector reported an error.") }
        return msg["result"] as? [String: Any] ?? [:]
    }

    func notify(_ method: String, _ params: [String: Any]) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func close() {}
}

/// A connected MCP server and its tools.
final class MCPConnection: @unchecked Sendable {
    let config: ConnectorConfig
    let transport: MCPTransport
    private(set) var tools: [(name: String, description: String, schema: [String: Any])] = []

    init(config: ConnectorConfig) throws {
        self.config = config
        switch config.kind {
        case .stdio: transport = try StdioTransport(command: config.command, args: config.args, env: config.env)
        case .http:
            guard let url = URL(string: config.url) else { throw MCPError(message: "That address isn’t valid.") }
            transport = HTTPTransport(url: url, headers: config.headers)
        }
    }

    func start() async throws {
        let result = try await withTimeout(30) { [transport] in
            try await transport.request("initialize", [
                "protocolVersion": "2025-06-18",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "Tarn", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"],
            ])
        }
        if let v = result["protocolVersion"] as? String { (transport as? HTTPTransport)?.setProtocolVersion(v) }
        try await transport.notify("notifications/initialized", [:])
        var cursor: String?
        var all: [(String, String, [String: Any])] = []
        repeat {
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let page = try await withTimeout(30) { [transport] in try await transport.request("tools/list", params) }
            for t in page["tools"] as? [[String: Any]] ?? [] {
                guard let name = t["name"] as? String else { continue }
                all.append((name, t["description"] as? String ?? "", t["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]))
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil && all.count < 500
        tools = all.map { (name: $0.0, description: $0.1, schema: $0.2) }
    }

    func call(_ tool: String, _ args: [String: Any]) async throws -> String {
        let result = try await withTimeout(120) { [transport] in try await transport.request("tools/call", ["name": tool, "arguments": args]) }
        let parts = result["content"] as? [[String: Any]] ?? []
        let text = parts.compactMap { p -> String? in
            switch p["type"] as? String {
            case "text": p["text"] as? String
            case "resource": (p["resource"] as? [String: Any]).flatMap { $0["text"] as? String ?? $0["uri"] as? String }
            case let t?: "[\(t)]"
            default: nil
            }
        }.joined(separator: "\n")
        if result["isError"] as? Bool == true { throw ToolFailure(text.isEmpty ? "The connector reported an error." : text) }
        return clip(text.isEmpty ? "(no output)" : text)
    }

    func close() { transport.close() }
}

func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw MCPError(message: "timed out")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// A connector tool exposed to the model as <connector>__<tool>. Every call needs approval.
struct ConnectorTool: Tool {
    let connection: MCPConnection
    let toolName: String
    let toolDescription: String
    let toolSchema: [String: Any]

    var name: String {
        let prefix = connection.config.name.lowercased().replacing(/[^a-z0-9]+/, with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(24)
        return String("\(prefix.isEmpty ? "connector" : String(prefix))__\(toolName)".replacing(/[^A-Za-z0-9_-]/, with: "_").prefix(64))
    }
    var description: String { String("[\(connection.config.name)] \(toolDescription)".prefix(1024)) }
    var parameters: [String: Any] { toolSchema }
    func label(_ args: [String: Any]) -> String { "Used \(connection.config.name): \(toolName)" }
    func approval(_ args: [String: Any], _ ctx: ToolContext) -> ApprovalRequest? {
        let json = (try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ApprovalRequest(title: "Let \(connection.config.name) run “\(toolName)”?", detail: clip(json, 3000))
    }
    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String { try await connection.call(toolName, args) }
}

func friendlyConnectorError(_ error: Error, _ cfg: ConnectorConfig) -> String {
    let msg = error.localizedDescription
    if cfg.kind == .stdio, msg.contains("not found") || msg.contains("No such file") {
        if ["npx", "node", "npm"].contains(cfg.command) { return "This connector needs Node.js. Install it from nodejs.org, then reconnect." }
        if ["uvx", "uv"].contains(cfg.command) { return "This connector needs uv. Install it from docs.astral.sh/uv, then reconnect." }
        return "The program “\(cfg.command)” wasn’t found on this Mac."
    }
    if msg.contains("timed out") { return "The connector didn’t respond in time." }
    if msg.contains("401") || msg.contains("403") { return "The connector refused the connection. Check its address and access key." }
    return String(msg.prefix(300))
}
