import AppKit
import Observation
import SwiftUI

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var isError = false
}

@MainActor @Observable
final class AppModel {
    // MARK: State the UI reads

    var booted = false
    var settings = AppSettings()
    var hardware: Hardware?
    var picks = Picks(recommended: nil, lighter: nil, budgetBytes: 0)
    var installed: [InstalledModel] = []
    var download: DownloadState = .idle
    var engineState: EngineState = .stopped
    var updates: [ModelUpdate] = []
    var dismissedUpdates: Set<String> = []
    var summaries: [ChatSummary] = []
    var currentId: String?
    var current: Chat?
    var connectors: [ConnectorConfig] = []
    var connectorStatus: [String: ConnectorStatus] = [:]
    var skills: [Skill] = []
    var memoryAlert: MemoryAlert?
    var toast: Toast?
    var drafts: [String: String] = [:]
    var searchOpen = false
    var sidebarVisible = NavigationSplitViewVisibility.all

    // MARK: Services

    @ObservationIgnored let store = ChatStore()
    @ObservationIgnored let engine = Engine()
    @ObservationIgnored let updater = Updater()
    @ObservationIgnored private let memory = MemoryWatcher()
    @ObservationIgnored private var downloader: Downloader?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var connections: [String: MCPConnection] = [:]
    @ObservationIgnored private var runs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var approvals: [String: (chatId: String, resume: CheckedContinuation<ApprovalDecision, Never>)] = [:]
    @ObservationIgnored private var allowedInChat: [String: Set<String>] = [:]
    @ObservationIgnored private var memoryQuietUntil = Date.distantPast
    @ObservationIgnored private var saveTimers: [String: Date] = [:]

    static let maxToolRounds = 24

    // MARK: Boot

    func boot() async {
        guard !booted else { return }
        settings = JSONFile.read(AppSettings.self, from: Paths.settings) ?? AppSettings()
        applyTheme()
        let hw = await HardwareInfo.detect()
        hardware = hw
        picks = ModelFit.picks(ramBytes: hw.ramBytes, gpuWorkingSetBytes: hw.gpuWorkingSetBytes, bandwidthGBs: hw.bandwidthGBs)
        let saved = JSONFile.read([InstalledModel].self, from: Paths.modelsState) ?? []
        installed = saved.filter { Catalog.model($0.id) != nil && FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent($0.fileName).path) }
        persistInstalled()
        summaries = store.summaries
        skills = Skills.list()
        connectors = JSONFile.read([ConnectorConfig].self, from: Paths.connectors) ?? []
        engine.onChange = { [weak self] s in self?.engineState = s }
        memory.onPressure = { [weak self] critical in self?.handlePressure(critical: critical) }
        memory.start()
        booted = true

        for c in connectors where c.enabled { connect(c) }
        if settings.onboarded {
            updater.start(autoUpdate: settings.autoUpdate)
            Task { await checkModelUpdates() }
            // Load the model in the background so the first answer doesn't wait for it.
            if activeModelId != nil { Task { try? await ensureEngine() } }
        }
        #if DEBUG
        debugAutomation()
        #endif
    }

    func saveSettings() {
        try? JSONFile.write(settings, to: Paths.settings)
    }

    func update(_ change: (inout AppSettings) -> Void) {
        let before = settings
        change(&settings)
        saveSettings()
        if before.theme != settings.theme { applyTheme() }
        if before.autoUpdate != settings.autoUpdate { updater.setAuto(settings.autoUpdate) }
        if before.idleUnloadMinutes != settings.idleUnloadMinutes, case .ready = engineState { Task { try? await ensureEngine() } }
    }

    func applyTheme() {
        NSApp.appearance = switch settings.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func finishOnboarding() {
        update { $0.onboarded = true }
        updater.start(autoUpdate: settings.autoUpdate)
        Task { await checkModelUpdates() }
        if activeModelId != nil { Task { try? await ensureEngine() } }
    }

    func showToast(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(error ? 6 : 3.5))
            if toast?.id == t.id { toast = nil }
        }
    }

    // MARK: Models

    var activeModelId: String? {
        let tier = settings.activeTier
        if let id = picks.pick(tier)?.model.id, isInstalled(id) { return id }
        let other: Tier = tier == .recommended ? .lighter : .recommended
        if let id = picks.pick(other)?.model.id, isInstalled(id) { return id }
        return installed.first?.id
    }

    var activeTier: Tier { picks.tier(of: activeModelId) ?? settings.activeTier }

    func isInstalled(_ id: String?) -> Bool { installed.contains { $0.id == id } }

    func contextFor(_ id: String) -> Int {
        [picks.recommended, picks.lighter].compactMap { $0 }.first { $0.model.id == id }?.contextTokens ?? 8192
    }

    private func persistInstalled() {
        try? JSONFile.write(installed, to: Paths.modelsState)
    }

    @discardableResult
    func ensureEngine() async throws -> String {
        guard let id = activeModelId, let m = installed.first(where: { $0.id == id }) else {
            throw ToolFailure("Tarn is still setting up its AI. Chat unlocks when the download finishes.")
        }
        try await engine.ensure(Engine.Config(modelId: id, modelPath: Paths.models.appendingPathComponent(m.fileName),
                                              contextTokens: contextFor(id), idleSeconds: settings.idleUnloadMinutes * 60))
        return id
    }

    func setTier(_ tier: Tier) {
        update { $0.activeTier = tier }
        if let id = picks.pick(tier)?.model.id, !isInstalled(id) { startDownload(id) }
        if activeModelId != nil { Task { try? await ensureEngine() } }
    }

    func startDownload(_ modelId: String, isUpdate: Bool = false) {
        guard let model = Catalog.model(modelId) else { return }
        if let current = download.modelId, current == modelId, case .downloading = download { return }
        if case .downloading = download { pauseDownload() }
        let update = isUpdate ? updates.first { $0.modelId == modelId && $0.kind == .file } : nil
        let size = update?.sizeBytes ?? model.file.size
        let sha = update?.sha256 ?? model.file.sha256
        let url = update == nil ? model.downloadURL : model.latestURL
        let fileName = "\(model.id)\(update == nil ? "" : ".update").gguf"
        let dest = Paths.models.appendingPathComponent(fileName)
        let part = dest.appendingPathExtension("part")
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        let needed = size - have + 500_000_000
        if HardwareInfo.freeDiskBytes() < needed {
            download = .failed(modelId: modelId, message: "Tarn needs \(Fmt.bytes(needed)) of free space for this download. Free up some space and try again.")
            return
        }
        let base = DownloadProgress(modelId: modelId, received: have, total: size, bytesPerSec: 0, isUpdate: update != nil)
        download = .downloading(base)
        let d = Downloader(url: url, dest: dest, expectedSize: size, expectedSHA256: sha, onProgress: { [weak self] p in
            Task { @MainActor in
                guard let self, case .downloading(var cur) = self.download, cur.modelId == modelId else { return }
                cur.received = p.received
                cur.bytesPerSec = p.bytesPerSec
                self.download = .downloading(cur)
            }
        }, onVerifying: { [weak self] in
            Task { @MainActor in
                guard let self, var cur = self.download.progress, cur.modelId == modelId else { return }
                cur.received = cur.total
                self.download = .verifying(cur)
            }
        })
        downloader = d
        // Keep the Mac awake while a multi-gigabyte download runs (the display may still sleep).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Downloading Tarn’s AI model")
        downloadTask = Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await d.run()
                await finishInstall(model, fileName: fileName, sha: sha, size: size, isUpdate: update != nil)
                download = .idle
            } catch let e as DownloadError where e.kind == .cancelled {
                if let p = download.progress, p.modelId == modelId { download = .paused(DownloadProgress(modelId: modelId, received: p.received, total: p.total, bytesPerSec: 0, isUpdate: p.isUpdate)) }
            } catch {
                download = .failed(modelId: modelId, message: error.localizedDescription)
            }
            if downloader === d { downloader = nil }
        }
    }

    private func finishInstall(_ model: CatalogModel, fileName: String, sha: String, size: Int64, isUpdate: Bool) async {
        var finalName = fileName
        if isUpdate {
            // Swap the improved file in; the engine must let go of the old one first.
            if engineState.modelId == model.id { await engine.stop() }
            finalName = "\(model.id).gguf"
            let finalURL = Paths.models.appendingPathComponent(finalName)
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.moveItem(at: Paths.models.appendingPathComponent(fileName), to: finalURL)
            updates.removeAll { $0.modelId == model.id && $0.kind == .file }
        }
        installed.removeAll { $0.id == model.id }
        installed.append(InstalledModel(id: model.id, fileName: finalName, sha256: sha, size: size, installedAt: Date()))
        persistInstalled()
        // A replacement finished: remove the model it replaces (unless it's still the lighter pick).
        if let repl = updates.first(where: { $0.kind == .replacement && $0.replacementId == model.id }) {
            updates.removeAll { $0 == repl }
            if repl.modelId != picks.lighter?.model.id { removeModel(repl.modelId) }
        }
        if model.id == activeModelId { Task { try? await ensureEngine() } }
    }

    func pauseDownload() {
        downloader?.cancel()
    }

    func cancelDownload() {
        let id = download.modelId
        downloader?.cancel()
        downloader = nil
        download = .idle
        if let id {
            for suffix in [".gguf.part", ".update.gguf.part"] {
                try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(id + suffix))
            }
        }
    }

    func removeModel(_ id: String) {
        guard let m = installed.first(where: { $0.id == id }) else { return }
        if engineState.modelId == id { Task { await engine.stop() } }
        try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(m.fileName))
        installed.removeAll { $0.id == id }
        persistInstalled()
    }

    /// Runs on every launch: asks Hugging Face whether each installed file was improved
    /// upstream (comparing SHA-256 from a HEAD request), and offers a replacement when an app
    /// update shipped a catalog that recommends a different model for this Mac. Never looks
    /// for brand-new models on its own.
    func checkModelUpdates() async {
        var found: [ModelUpdate] = []
        let session = URLSession(configuration: .ephemeral, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for m in installed {
            guard let model = Catalog.model(m.id) else { continue }
            var req = URLRequest(url: model.latestURL, timeoutInterval: 10)
            req.httpMethod = "HEAD"
            guard let (_, res) = try? await session.data(for: req), let http = res as? HTTPURLResponse else { continue }
            let etag = (http.value(forHTTPHeaderField: "x-linked-etag") ?? "").replacingOccurrences(of: "\"", with: "").lowercased()
            let size = Int64(http.value(forHTTPHeaderField: "x-linked-size") ?? "") ?? 0
            if etag.count == 64, etag.allSatisfy(\.isHexDigit), etag != m.sha256, size > 0 {
                found.append(ModelUpdate(modelId: m.id, kind: .file, replacementId: nil, sizeBytes: size, sha256: etag))
            }
        }
        if let rec = picks.recommended?.model, !isInstalled(rec.id),
           let outdated = installed.first(where: { $0.id != picks.lighter?.model.id }) {
            found.append(ModelUpdate(modelId: outdated.id, kind: .replacement, replacementId: rec.id, sizeBytes: rec.file.size, sha256: nil))
        }
        updates = found
    }

    func applyUpdate(_ u: ModelUpdate) {
        if u.kind == .file { startDownload(u.modelId, isUpdate: true) } else if let r = u.replacementId { startDownload(r) }
    }

    // MARK: Memory

    private func handlePressure(critical: Bool) {
        guard settings.memoryGuard, case .ready(let id, _) = engineState, !engine.likelyAsleep, Date() > memoryQuietUntil, memoryAlert == nil else { return }
        // Only speak up if pressure is still there a few seconds later.
        Task {
            try? await Task.sleep(for: .seconds(8))
            guard MemoryWatcher.level() >= 2, memoryAlert == nil else { return }
            let pick = [picks.recommended, picks.lighter].compactMap { $0 }.first { $0.model.id == id }
            memoryAlert = MemoryAlert(critical: critical || MemoryWatcher.level() >= 4, onLighter: picks.lighter == nil || picks.lighter?.model.id == id,
                                      engineGB: pick.map { (Double($0.footprintBytes) / 1e8).rounded() / 10 })
            if !NSApp.isActive {
                MemoryWatcher.notify(title: "Your Mac is running low on memory",
                                     body: memoryAlert?.onLighter == true ? "Tarn’s AI is holding memory you may need. Open Tarn to free it."
                                         : "Switch Tarn to the lighter model to give memory back to your other apps.")
            }
        }
    }

    func dismissMemoryAlert() {
        memoryAlert = nil
        memoryQuietUntil = Date().addingTimeInterval(30 * 60)
    }

    func freeMemory() {
        dismissMemoryAlert()
        Task { await engine.stop() }
    }

    // MARK: Chats

    func openChat(_ id: String?) {
        currentId = id
        current = id.flatMap { store.chats[$0] }
    }

    func newChat() {
        currentId = nil
        current = nil
    }

    private func mutate(_ chatId: String, persist: Bool = true, _ change: (inout Chat) -> Void) {
        guard var chat = store.chats[chatId] else { return }
        change(&chat)
        if persist { store.save(chat) } else { storeInMemory(chat) }
        if currentId == chatId { current = chat }
    }

    private func storeInMemory(_ chat: Chat) {
        // Keep the cache current without hitting the disk on every streamed word.
        store.save(chat, toDisk: false)
    }

    private func refreshSummaries() {
        summaries = store.summaries
    }

    func renameChat(_ id: String, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(id) { $0.title = String(t.prefix(200)) }
        refreshSummaries()
    }

    func togglePin(_ id: String) {
        mutate(id) { $0.pinned.toggle() }
        refreshSummaries()
    }

    func deleteChat(_ id: String) {
        stop(id)
        store.delete(id)
        if currentId == id { newChat() }
        refreshSummaries()
    }

    func deleteAllChats() {
        for id in runs.keys { stop(id) }
        store.deleteAll()
        newChat()
        refreshSummaries()
    }

    func shareFolder() {
        let panel = NSOpenPanel()
        panel.title = "Share a folder with Tarn"
        panel.message = "Tarn can read files in this folder and, with your approval, change them and run commands in it."
        panel.prompt = "Share folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let id = currentId ?? createChat().id
        mutate(id) { $0.folder = url.path }
    }

    func stopSharingFolder() {
        guard let id = currentId else { return }
        mutate(id) { $0.folder = nil }
    }

    @discardableResult
    private func createChat() -> Chat {
        let c = store.create()
        currentId = c.id
        current = c
        return c
    }

    func pickAttachments() -> [Attachment] {
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.prompt = "Attach"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return readAttachments(panel.urls)
    }

    func readAttachments(_ urls: [URL]) -> [Attachment] {
        var out: [Attachment] = []
        for u in urls.prefix(10) {
            do { out.append(try Attachments.read(u)) } catch { showToast(error.localizedDescription, error: true) }
        }
        return out
    }

    func send(_ text: String, attachments: [Attachment]) -> Bool {
        guard activeModelId != nil else {
            showToast("Tarn is still setting up its AI. Chat unlocks when the download finishes.", error: true)
            return false
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachments.isEmpty else { return false }
        let id = currentId ?? createChat().id
        guard runs[id] == nil else { return false }
        mutate(id) {
            $0.messages.append(Message(id: newId(), role: .user, createdAt: Date(), text: body.isEmpty ? "Please look at the attached file." : String(body.prefix(200_000)),
                                       attachments: attachments.isEmpty ? nil : attachments))
            $0.updatedAt = Date()
        }
        refreshSummaries()
        respond(id)
        return true
    }

    func retry(_ chatId: String) {
        guard runs[chatId] == nil else { return }
        mutate(chatId) { c in while c.messages.last?.role == .assistant { c.messages.removeLast() } }
        respond(chatId)
    }

    func editAndResend(_ chatId: String, messageId: String, text: String) {
        guard runs[chatId] == nil, let i = store.chats[chatId]?.messages.firstIndex(where: { $0.id == messageId && $0.role == .user }) else { return }
        mutate(chatId) { c in
            c.messages[i].text = text
            c.messages = Array(c.messages.prefix(i + 1))
        }
        respond(chatId)
    }

    func stop(_ chatId: String) {
        runs[chatId]?.cancel()
        for (blockId, a) in approvals where a.chatId == chatId {
            approvals[blockId] = nil
            a.resume.resume(returning: .deny)
        }
    }

    func isAnswering(_ chatId: String?) -> Bool { chatId.map { runs[$0] != nil } ?? false }

    func approve(_ blockId: String, _ decision: ApprovalDecision) {
        guard let a = approvals.removeValue(forKey: blockId) else { return }
        a.resume.resume(returning: decision)
    }

    // MARK: Agent loop

    private func availableTools(_ chat: Chat) -> [Tool] {
        var tools: [Tool] = []
        if settings.webSearch { tools += [WebSearchTool(), FetchPageTool()] }
        if chat.folder != nil { tools += [ListFilesTool(), ReadFileTool(), SearchFilesTool(), WriteFileTool(), EditFileTool(), RunCommandTool()] }
        if !Skills.enabled().isEmpty { tools.append(UseSkillTool()) }
        for c in connectors where c.enabled {
            guard let conn = connections[c.id] else { continue }
            tools += conn.tools.map { ConnectorTool(connection: conn, toolName: $0.name, toolDescription: $0.description, toolSchema: $0.schema) }
        }
        return tools
    }

    private func setMessage(_ chatId: String, _ messageId: String, persist: Bool = false, _ change: (inout Message) -> Void) {
        mutate(chatId, persist: persist) { c in
            if let i = c.messages.firstIndex(where: { $0.id == messageId }) { change(&c.messages[i]) }
        }
    }

    private func respond(_ chatId: String) {
        let messageId = newId()
        mutate(chatId) { $0.messages.append(Message(id: messageId, role: .assistant, createdAt: Date(), status: .streaming)) }
        runs[chatId] = Task { await self.runAgent(chatId: chatId, messageId: messageId) }
    }

    private func runAgent(chatId: String, messageId: String) async {
        var tokens = 0
        var genMs = 0.0
        let started = Date()
        do {
            let modelId = try await ensureEngine()
            try Task.checkCancellation()
            setMessage(chatId, messageId) { $0.modelId = modelId }
            let model = Catalog.model(modelId)
            let ctx: Int = if case .ready(_, let c) = engineState { c } else { contextFor(modelId) }
            let thinking = model?.thinking == .always || (model?.thinking == .optional && settings.thinking)
            let sampling = (thinking ? model?.thinkingSampling : nil) ?? model?.sampling
            let maxOutput = min(8192, ctx / 3)

            for round in 0...Self.maxToolRounds {
                guard let chat = store.chats[chatId] else { return }
                let tools = round < Self.maxToolRounds ? availableTools(chat) : []
                let defs = tools.map(\.definition)
                let toolsLen = (try? JSONSerialization.data(withJSONObject: defs).count) ?? 0
                let past = chat.messages.filter { !($0.id == messageId && $0.blocks.isEmpty) }
                let history = Prompt.history(past, keepFull: 2, attachmentChars: Int(Double(ctx) * Prompt.charsPerToken * 0.45))
                let system = Prompt.system(chat: chat, settings: settings, toolNames: Set(tools.map(\.name)), skills: Skills.enabled())
                var messages = Prompt.fit(system: system, history: history, toolsJSONLength: toolsLen, budget: ctx - maxOutput - 256)

                var calls: [Int: (id: String, name: String, args: String)] = [:]
                var attempt = 0
                while true {
                    var body: [String: Any] = ["model": "tarn", "messages": messages, "stream": true, "max_tokens": maxOutput, "cache_prompt": true]
                    if !defs.isEmpty {
                        body["tools"] = defs
                        body["tool_choice"] = "auto"
                        body["parallel_tool_calls"] = false
                    }
                    if let s = sampling {
                        body["temperature"] = s.temperature
                        body["top_p"] = s.top_p
                        body["top_k"] = s.top_k
                        body["min_p"] = s.min_p
                        if let p = s.presence_penalty { body["presence_penalty"] = p }
                    }
                    if model?.thinking == .optional { body["chat_template_kwargs"] = ["enable_thinking": thinking] }
                    engine.markActive()
                    do {
                        try await streamRound(chatId: chatId, messageId: messageId, body: body, calls: &calls, tokens: &tokens, genMs: &genMs)
                        break
                    } catch LLMError.contextOverflow where attempt == 0 {
                        // The estimate was off: retry once with half the history.
                        attempt += 1
                        var rest = Array(messages.dropFirst())
                        rest = Array(rest.suffix(max(1, rest.count / 2)))
                        while rest.count > 1, rest.first?["role"] as? String != "user" { rest.removeFirst() }
                        messages = [messages[0]] + rest
                    }
                }
                engine.markActive()
                if calls.isEmpty { break }
                for key in calls.keys.sorted() {
                    try Task.checkCancellation()
                    guard let call = calls[key] else { continue }
                    await runTool(chatId: chatId, messageId: messageId, tools: tools, call: call)
                    if let c = store.chats[chatId] { store.save(c) }
                }
                try Task.checkCancellation()
            }
            setMessage(chatId, messageId) { $0.status = .done }
            if store.chats[chatId]?.messages.first(where: { $0.id == messageId })?.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                update { $0.water.answers += 1; $0.water.ml += Water.mlPerAnswer }
            }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            setMessage(chatId, messageId) { m in
                if cancelled {
                    m.status = .stopped
                    for i in m.blocks.indices {
                        if case .tool(var t) = m.blocks[i], t.status == .running || t.status == .awaitingApproval {
                            t.status = .denied
                            t.approval = nil
                            m.blocks[i] = .tool(t)
                        }
                    }
                } else {
                    m.status = .error
                    m.error = error.localizedDescription
                }
            }
        }
        setMessage(chatId, messageId, persist: true) { m in
            m.tokens = tokens
            m.ms = Int(genMs > 0 ? genMs : Date().timeIntervalSince(started) * 1000)
        }
        mutate(chatId) { $0.updatedAt = Date() }
        runs[chatId] = nil
        refreshSummaries()
        if store.chats[chatId]?.title == "New chat", store.chats[chatId]?.messages.last?.status == .done { await nameChat(chatId) }
    }

    /// Streams one model turn into the message, batching UI updates to ~16 per second.
    private func streamRound(chatId: String, messageId: String, body: [String: Any],
                             calls: inout [Int: (id: String, name: String, args: String)], tokens: inout Int, genMs: inout Double) async throws {
        var pendingText = ""
        var pendingThinking = ""
        var thinkingStart: Date?
        var lastFlush = Date()
        func flush() {
            guard !pendingText.isEmpty || !pendingThinking.isEmpty else { return }
            let t = pendingText, th = pendingThinking
            pendingText = ""
            pendingThinking = ""
            let elapsed = thinkingStart.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            setMessage(chatId, messageId) { m in
                if !th.isEmpty {
                    if case .thinking(let old, _) = m.blocks.last { m.blocks[m.blocks.count - 1] = .thinking(text: old + th, ms: elapsed) }
                    else { m.blocks.append(.thinking(text: th, ms: elapsed)) }
                }
                if !t.isEmpty {
                    if case .text(let old) = m.blocks.last { m.blocks[m.blocks.count - 1] = .text(old + t) } else { m.blocks.append(.text(t)) }
                }
            }
        }
        for try await chunk in LLM.stream(baseURL: engine.baseURL, apiKey: engine.apiKey, body: body) {
            try Task.checkCancellation()
            if let e = chunk.error { throw ToolFailure(e) }
            if let r = chunk.reasoning, !r.isEmpty {
                if thinkingStart == nil { thinkingStart = Date() }
                pendingThinking += r
            }
            if let c = chunk.content, !c.isEmpty {
                if !pendingThinking.isEmpty { flush() }
                pendingText += c
            }
            for d in chunk.toolCalls {
                var c = calls[d.index] ?? (id: "", name: "", args: "")
                if let id = d.id { c.id = id }
                if let n = d.name { c.name += n }
                if let a = d.arguments { c.args += a }
                calls[d.index] = c
            }
            if let n = chunk.predictedTokens { tokens += n; genMs += chunk.predictedMs ?? 0 }
            if Date().timeIntervalSince(lastFlush) > 0.06 {
                flush()
                lastFlush = Date()
            }
        }
        flush()
    }

    private func runTool(chatId: String, messageId: String, tools: [Tool], call: (id: String, name: String, args: String)) async {
        let tool = tools.first { $0.name == call.name }
        let blockId = call.id.isEmpty ? "call_\(newId())" : call.id
        var args: [String: Any] = [:]
        var parseError = false
        let raw = call.args.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] { args = obj } else { parseError = true }
        }
        var block = ToolBlock(id: blockId, name: call.name, label: tool?.label(args) ?? "Tried to use \(call.name)", args: call.args, status: .running)
        func save(_ b: ToolBlock) {
            setMessage(chatId, messageId) { m in
                if let i = m.blocks.lastIndex(where: { if case .tool(let t) = $0 { t.id == b.id } else { false } }) { m.blocks[i] = .tool(b) }
                else { m.blocks.append(.tool(b)) }
            }
        }
        save(block)
        guard let tool else {
            block.status = .error
            block.result = "There is no tool called \"\(call.name)\". Available tools: \(tools.map(\.name).joined(separator: ", "))."
            return save(block)
        }
        if parseError {
            block.status = .error
            block.result = "The arguments were not valid JSON. Call the tool again with a JSON object."
            return save(block)
        }
        guard let chat = store.chats[chatId] else { return }
        let ctx = ToolContext(chat: chat)
        if let request = tool.approval(args, ctx), !(allowedInChat[chatId]?.contains(tool.name) ?? false) {
            block.status = .awaitingApproval
            block.approval = request
            save(block)
            let decision: ApprovalDecision = await withCheckedContinuation { c in
                if Task.isCancelled { c.resume(returning: .deny) } else { approvals[blockId] = (chatId, c) }
            }
            block.approval = nil
            if decision == .deny {
                block.status = .denied
                block.result = "The user declined this action."
                return save(block)
            }
            if decision == .chat { allowedInChat[chatId, default: []].insert(tool.name) }
            block.status = .running
            save(block)
        }
        do {
            block.result = try await tool.run(args, ctx)
            block.status = .done
        } catch {
            block.status = .error
            block.result = (error as? ToolFailure)?.message ?? "The tool failed: \(error.localizedDescription)"
        }
        save(block)
    }

    private func nameChat(_ chatId: String) async {
        guard let first = store.chats[chatId]?.messages.first(where: { $0.role == .user }) else { return }
        var title = first.text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        title = String(title.prefix(60))
        if case .ready(let id, _) = engineState {
            var body: [String: Any] = [
                "model": "tarn", "max_tokens": 24, "temperature": 0.3, "stream": false,
                "messages": [
                    ["role": "system", "content": "You write short titles for conversations. Reply with the title only: 2 to 6 words, no quotes, no punctuation at the end."],
                    ["role": "user", "content": "Title for a conversation that starts with:\n\n\(first.text.prefix(1500))"],
                ],
            ]
            if Catalog.model(id)?.thinking == .optional { body["chat_template_kwargs"] = ["enable_thinking": false] }
            if let t = try? await LLM.complete(baseURL: engine.baseURL, apiKey: engine.apiKey, body: body) {
                let clean = t.replacing(/(?s)<think>.*?<\/think>/, with: "").replacing(/["“”*#]/, with: "")
                    .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !clean.isEmpty, clean.count <= 80 { title = clean.hasSuffix(".") || clean.hasSuffix("!") ? String(clean.dropLast()) : clean }
            }
        }
        if store.chats[chatId]?.title == "New chat" { renameChat(chatId, title.isEmpty ? "Untitled chat" : title) }
    }

    // MARK: Connectors

    private func persistConnectors() {
        try? JSONFile.write(connectors, to: Paths.connectors)
    }

    func connect(_ cfg: ConnectorConfig) {
        connections[cfg.id]?.close()
        connections[cfg.id] = nil
        guard cfg.enabled else {
            connectorStatus[cfg.id] = ConnectorStatus(state: .off)
            return
        }
        connectorStatus[cfg.id] = ConnectorStatus(state: .connecting)
        Task {
            do {
                let conn = try MCPConnection(config: cfg)
                try await conn.start()
                connections[cfg.id] = conn
                connectorStatus[cfg.id] = ConnectorStatus(state: .connected, tools: conn.tools.map(\.name))
            } catch {
                connectorStatus[cfg.id] = ConnectorStatus(state: .failed(friendlyConnectorError(error, cfg)))
            }
        }
    }

    func upsertConnector(_ cfg: ConnectorConfig) {
        if let i = connectors.firstIndex(where: { $0.id == cfg.id }) { connectors[i] = cfg } else { connectors.append(cfg) }
        persistConnectors()
        connect(cfg)
    }

    func removeConnector(_ id: String) {
        connections[id]?.close()
        connections[id] = nil
        connectors.removeAll { $0.id == id }
        connectorStatus[id] = nil
        persistConnectors()
    }

    /// Imports servers the user already set up in Claude Desktop.
    func importClaudeConnectors() {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: [String: Any]] else {
            return showToast("Claude Desktop’s connector settings weren’t found on this Mac.", error: true)
        }
        var added = 0
        for (name, s) in servers.sorted(by: { $0.key < $1.key }) where !connectors.contains(where: { $0.name == name }) {
            if let cmd = s["command"] as? String {
                upsertConnector(ConnectorConfig(id: newId(), name: name, kind: .stdio, command: cmd, args: s["args"] as? [String] ?? [], env: s["env"] as? [String: String] ?? [:], enabled: true))
                added += 1
            } else if let url = s["url"] as? String {
                upsertConnector(ConnectorConfig(id: newId(), name: name, kind: .http, url: url, enabled: true))
                added += 1
            }
        }
        showToast(added > 0 ? "Added \(added) connector\(added == 1 ? "" : "s") from Claude Desktop." : "No new connectors found in Claude Desktop.")
    }

    // MARK: Skills

    func refreshSkills() { skills = Skills.list() }

    // MARK: Backup

    func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "Back up Tarn"
        panel.prompt = "Save backup"
        panel.nameFieldStringValue = "Tarn Backup \(Date().formatted(.iso8601.year().month().day())).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chats = Array(store.chats.values)
        do {
            try Backup.export(to: url, chats: chats, settings: settings, connectors: connectors)
            showToast("Saved a backup of \(chats.filter { !$0.messages.isEmpty }.count) chats.")
        } catch {
            showToast("Couldn’t save the backup: \(error.localizedDescription)", error: true)
        }
    }

    /// replace: fresh install (onboarding). merge: from Settings; for chats in both, the newer one wins.
    @discardableResult
    func importBackup(replace: Bool) -> ImportResult? {
        let panel = NSOpenPanel()
        panel.title = "Restore from a Tarn backup"
        panel.prompt = "Restore"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let contents = try Backup.read(url)
            for id in runs.keys { stop(id) }
            if replace { store.deleteAll() }
            var result = ImportResult(skipped: contents.skipped)
            for chat in contents.chats {
                if !replace, let existing = store.chats[chat.id], existing.updatedAt >= chat.updatedAt { result.chats += 1; continue }
                store.save(chat)
                result.chats += 1
            }
            if var s = contents.settings {
                s.onboarded = settings.onboarded
                s.activeTier = settings.activeTier
                if !replace {
                    s.theme = settings.theme
                    s.water = s.water.ml > settings.water.ml ? s.water : settings.water
                }
                settings = s
                saveSettings()
                applyTheme()
            }
            result.skills = Backup.restoreSkills(contents.skillFiles)
            // Connectors arrive switched off, so a crafted backup can't start programs on this Mac.
            for var c in contents.connectors where !connectors.contains(where: { $0.id == c.id || $0.name == c.name }) {
                c.enabled = false
                connectors.append(c)
                connectorStatus[c.id] = ConnectorStatus(state: .off)
                result.connectors += 1
            }
            persistConnectors()
            refreshSkills()
            refreshSummaries()
            newChat()
            showToast("Restored \(result.chats) chat\(result.chats == 1 ? "" : "s")\(result.skipped > 0 ? " (\(result.skipped) couldn’t be read)" : "").")
            return result
        } catch {
            showToast(error.localizedDescription, error: true)
            return nil
        }
    }

    // MARK: Quit

    func shutdown() {
        for id in runs.keys { stop(id) }
        engine.killNow()
        for c in connections.values { c.close() }
    }

    #if DEBUG
    /// Test hook for scripted runs: `-TarnAutoSend "question"` sends once the model is ready.
    private func debugAutomation() {
        guard let text = UserDefaults.standard.string(forKey: "TarnAutoSend"), settings.onboarded else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if let folder = UserDefaults.standard.string(forKey: "TarnAutoFolder") {
                let c = createChat()
                mutate(c.id) { $0.folder = folder }
            }
            _ = send(text, attachments: [])
        }
    }
    #endif
}

/// Stops URLSession from following redirects (HF's resolve endpoint answers HEAD with a 302
/// that carries the file's hash).
final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
