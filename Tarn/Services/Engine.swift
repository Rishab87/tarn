import Foundation

/// Runs llama.cpp's llama-server as a child process bound to 127.0.0.1 on a random port and
/// protected by a random API key, so other apps and web pages on this Mac can't use it.
@MainActor
final class Engine {
    struct Config: Equatable {
        var modelId: String
        var modelPath: URL
        var contextTokens: Int
        var idleSeconds: Int
    }

    private(set) var state: EngineState = .stopped {
        didSet { onChange?(state) }
    }
    var onChange: ((EngineState) -> Void)?

    private var process: Process?
    private var config: Config?
    private var starting: Task<Void, Error>?
    private(set) var port = 0
    private(set) var apiKey = ""
    private var lastActive = Date()
    private var stopping = false

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func markActive() { lastActive = Date() }

    /// llama-server unloads the model after `--sleep-idle-seconds`; this tells whether it probably did.
    var likelyAsleep: Bool {
        guard let idle = config?.idleSeconds, idle > 0 else { return false }
        return Date().timeIntervalSince(lastActive) > Double(idle) + 5
    }

    /// Starts the engine with this model, or does nothing if it's already running it.
    func ensure(_ cfg: Config) async throws {
        if let starting, config == cfg { return try await starting.value }
        if process?.isRunning == true, config == cfg, case .ready = state { return }
        await stop()
        config = cfg
        let task = Task { try await self.start(cfg) }
        starting = task
        defer { if config == cfg { starting = nil } }
        try await task.value
    }

    private func start(_ cfg: Config) async throws {
        guard let bin = Paths.llamaServer, FileManager.default.isExecutableFile(atPath: bin.path) else {
            state = .failed(modelId: cfg.modelId, message: "Tarn’s AI engine is missing. Download Tarn again from its website.")
            throw EngineError.missing
        }
        Self.killStale(binary: bin)
        port = try Self.freePort()
        apiKey = Self.randomKey()
        state = .starting(modelId: cfg.modelId)

        let p = Process()
        // A small zsh watchdog runs llama-server and kills it within a second if Tarn goes away
        // for any reason (crash, force quit), so the model's memory is never left behind.
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", Self.watchdog, "tarn-engine", bin.path] + [
            "-m", cfg.modelPath.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--api-key", apiKey,
            "-c", String(cfg.contextTokens),
            "-np", "1",
            "-ngl", "all",
            "--fit", "off",
            "-fa", "auto",
            "-ctk", "q8_0",
            "-ctv", "q8_0",
            "--jinja",
            "--reasoning-format", "deepseek",
            "--no-webui",
            // llama-server keeps earlier prompts in RAM for reuse (default up to 8 GiB). Cap it
            // so Tarn stays inside the memory budget it chose for this Mac.
            "--cache-ram", String(ModelFit.promptCacheMiB),
            "--sleep-idle-seconds", cfg.idleSeconds > 0 ? String(cfg.idleSeconds) : "-1",
        ]
        let logURL = Paths.logs.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        stopping = false
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.process = nil
                try? FileManager.default.removeItem(at: Self.pidFile)
                if !self.stopping {
                    let msg = reason == .uncaughtSignal ? "macOS stopped the AI engine (signal \(status))." : "The AI engine stopped unexpectedly."
                    self.state = .failed(modelId: cfg.modelId, message: msg)
                }
            }
        }
        try p.run()
        process = p
        try? String(p.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)

        // Loading a model takes a few seconds; big ones on slow disks can take a minute.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if !p.isRunning {
                let tail = (try? String(contentsOf: logURL, encoding: .utf8)).map { String($0.suffix(4000)) } ?? ""
                state = .failed(modelId: cfg.modelId, message: Self.friendlyStartError(tail))
                throw EngineError.exited
            }
            if await healthy() {
                markActive()
                state = .ready(modelId: cfg.modelId, contextTokens: cfg.contextTokens)
                return
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        await stop()
        state = .failed(modelId: cfg.modelId, message: "The AI took too long to start.")
        throw EngineError.timeout
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 2)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (_, res) = try? await URLSession.shared.data(for: req) else { return false }
        return (res as? HTTPURLResponse)?.statusCode == 200
    }

    func stop() async {
        starting?.cancel()
        starting = nil
        config = nil
        guard let p = process else {
            if case .failed = state {} else { state = .stopped }
            return
        }
        stopping = true
        p.terminate()
        for _ in 0..<50 where p.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
        state = .stopped
    }

    /// Synchronous kill for app termination.
    func killNow() {
        stopping = true
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    enum EngineError: Error { case missing, exited, timeout }

    /// $@ is llama-server and its arguments. Exits with llama-server's status.
    static let watchdog = """
    "$@" &
    child=$!
    trap 'kill -TERM $child 2>/dev/null; wait $child; exit 143' TERM INT HUP
    while kill -0 $PPID 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
    kill -TERM $child 2>/dev/null
    wait $child
    """

    private static var pidFile: URL { Paths.data.appendingPathComponent("engine.pid") }

    /// If Tarn crashed earlier, its llama-server may still be running and holding memory.
    private static func killStale(binary: URL) {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let cmd = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        if cmd.contains(binary.path) { kill(pid, SIGTERM) }
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.exited }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard bound else { throw EngineError.exited }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func friendlyStartError(_ log: String) -> String {
        let l = log.lowercased()
        if l.contains("failed to allocate") || l.contains("out of memory") || l.contains("insufficient memory") {
            return "Your Mac didn’t have enough free memory to load the AI. Close some apps or switch to the lighter model."
        }
        if l.contains("failed to load model") || l.contains("invalid magic") {
            return "The AI model file looks damaged. Delete it in Settings → AI Model and download it again."
        }
        return "The AI engine couldn’t start. Quit Tarn, open it again, and try once more."
    }
}
