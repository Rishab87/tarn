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
    /// Sidebar folders, sorted by name.
    var groups: [ChatGroup] = []
    var currentId: String?
    var current: Chat?
    var connectors: [ConnectorConfig] = []
    var connectorStatus: [String: ConnectorStatus] = [:]
    var skills: [Skill] = []
    var memories: [MemoryItem] = []
    var memoryAlert: MemoryAlert?
    var toast: Toast?
    var drafts: [String: String] = [:]
    var searchOpen = false
    var onboardingStep = 0
    var settingsTab = "general"
    /// Bumped to ask the root view to open the Settings window.
    var openSettingsRequest = 0
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
        var hw = await HardwareInfo.detect()
        #if DEBUG
        // Test hook: -TarnTheme dark forces the appearance for screenshots.
        if let raw = UserDefaults.standard.string(forKey: "TarnTheme"), let theme = ThemeChoice(rawValue: raw) { update { $0.theme = theme } }
        // Test hook: -TarnSimulateRAMGB 8 makes model picks behave like a Mac with that much memory.
        let simGB = UserDefaults.standard.integer(forKey: "TarnSimulateRAMGB")
        if simGB > 0 {
            hw.ramBytes = Int64(simGB) << 30
            hw.gpuWorkingSetBytes = Int64(Double(hw.ramBytes) * 0.67)
        }
        #endif
        hardware = hw
        picks = ModelFit.picks(ramBytes: hw.ramBytes, gpuWorkingSetBytes: hw.gpuWorkingSetBytes, bandwidthGBs: hw.bandwidthGBs)
        let saved = JSONFile.read([InstalledModel].self, from: Paths.modelsState) ?? []
        installed = saved.filter { Catalog.model($0.id) != nil && FileManager.default.fileExists(atPath: Paths.models.appendingPathComponent($0.fileName).path) }
        persistInstalled()
        summaries = store.summaries
        groups = store.groups
        skills = Skills.list()
        memories = MemoryStore.load()
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
            ensureVisionAddOn()
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
        for other in [Tier.recommended, .lighter, .bigger] where other != tier {
            if let id = picks.pick(other)?.model.id, isInstalled(id) { return id }
        }
        return installed.first?.id
    }

    var activeTier: Tier { picks.tier(of: activeModelId) ?? settings.activeTier }

    func isInstalled(_ id: String?) -> Bool { installed.contains { $0.id == id } }

    func contextFor(_ id: String) -> Int {
        [picks.recommended, picks.lighter, picks.bigger].compactMap { $0 }.first { $0.model.id == id }?.contextTokens ?? 8192
    }

    /// Models larger than the memory budget let llama.cpp decide how many layers fit on the GPU.
    func needsFit(_ id: String) -> Bool {
        guard let p = [picks.recommended, picks.lighter, picks.bigger].compactMap({ $0 }).first(where: { $0.model.id == id }) else { return false }
        return p.footprintBytes > picks.budgetBytes
    }

    private func persistInstalled() {
        try? JSONFile.write(installed, to: Paths.modelsState)
    }

    @discardableResult
    func ensureEngine(needVision: Bool = false) async throws -> String {
        guard let id = activeModelId, let m = installed.first(where: { $0.id == id }) else {
            throw ToolFailure("Tarn is still setting up its AI. Chat unlocks when the download finishes.")
        }
        var vision: URL?
        if needVision {
            guard let file = m.visionFileName else { throw ToolFailure(visionMissingMessage(id)) }
            vision = Paths.models.appendingPathComponent(file)
        } else if let cur = engine.currentConfig, cur.modelId == id, cur.visionPath != nil {
            vision = cur.visionPath // already loaded: keep it rather than restarting
        }
        try await engine.ensure(Engine.Config(modelId: id, modelPath: Paths.models.appendingPathComponent(m.fileName),
                                              contextTokens: contextFor(id), idleSeconds: settings.idleUnloadMinutes * 60, visionPath: vision,
                                              fitToDevice: needsFit(id)))
        return id
    }

    private func visionMissingMessage(_ id: String) -> String {
        if download.modelId == id, download.isVision, let p = download.progress {
            return "Tarn is still downloading its image add-on (\(Int(p.fraction * 100))%). Send the image again when it finishes."
        }
        startDownload(id, vision: true)
        return "Tarn needs a small add-on to see images. It’s downloading now; send the image again when it finishes."
    }

    /// Fetches the image add-on for the active model in the background, if it's missing.
    func ensureVisionAddOn() {
        guard let id = activeModelId, let m = installed.first(where: { $0.id == id }), m.visionFileName == nil,
              Catalog.model(id)?.vision != nil, download == .idle else { return }
        startDownload(id, vision: true)
    }

    func setTier(_ tier: Tier) {
        update { $0.activeTier = tier }
        if let id = picks.pick(tier)?.model.id, !isInstalled(id) { startDownload(id) }
        if activeModelId != nil { Task { try? await ensureEngine() } }
    }

    func startDownload(_ modelId: String, isUpdate: Bool = false, vision: Bool = false) {
        guard let model = Catalog.model(modelId) else { return }
        if download.modelId == modelId, download.isVision == vision, case .downloading = download { return }
        if case .downloading = download { pauseDownload() }
        let update = isUpdate && !vision ? updates.first { $0.modelId == modelId && $0.kind == .file } : nil
        if vision && model.vision == nil { return }
        let size = vision ? model.vision!.size : (update?.sizeBytes ?? model.file.size)
        let sha = vision ? model.vision!.sha256 : (update?.sha256 ?? model.file.sha256)
        let url = vision ? model.visionURL! : (update == nil ? model.downloadURL : model.latestURL)
        let fileName = vision ? "\(model.id).mmproj.gguf" : "\(model.id)\(update == nil ? "" : ".update").gguf"
        let dest = Paths.models.appendingPathComponent(fileName)
        let part = dest.appendingPathExtension("part")
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        let needed = size - have + 500_000_000
        if HardwareInfo.freeDiskBytes() < needed {
            download = .failed(modelId: modelId, message: "Tarn needs \(Fmt.bytes(needed)) of free space for this download. Free up some space and try again.", isVision: vision)
            return
        }
        let base = DownloadProgress(modelId: modelId, received: have, total: size, bytesPerSec: 0, isUpdate: update != nil, isVision: vision)
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
                if vision {
                    if let i = installed.firstIndex(where: { $0.id == model.id }) {
                        installed[i].visionFileName = fileName
                        persistInstalled()
                    }
                    download = .idle
                } else {
                    await finishInstall(model, fileName: fileName, sha: sha, size: size, isUpdate: update != nil)
                    download = .idle
                    ensureVisionAddOn()
                }
            } catch let e as DownloadError where e.kind == .cancelled {
                if let p = download.progress, p.modelId == modelId {
                    download = .paused(DownloadProgress(modelId: modelId, received: p.received, total: p.total, bytesPerSec: 0, isUpdate: p.isUpdate, isVision: p.isVision))
                }
            } catch {
                download = .failed(modelId: modelId, message: error.localizedDescription, isVision: vision)
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
            for suffix in [".gguf.part", ".update.gguf.part", ".mmproj.gguf.part"] {
                try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(id + suffix))
            }
        }
    }

    func removeModel(_ id: String) {
        guard let m = installed.first(where: { $0.id == id }) else { return }
        if engineState.modelId == id { Task { await engine.stop() } }
        try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(m.fileName))
        if let v = m.visionFileName { try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(v)) }
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
        // Speak up only for sustained pressure (~45 s) or a critical spike, not brief blips.
        Task {
            if !critical {
                for _ in 0..<3 {
                    try? await Task.sleep(for: .seconds(15))
                    guard MemoryWatcher.level() >= 2 else { return }
                }
            } else {
                try? await Task.sleep(for: .seconds(3))
            }
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
        if groups != store.groups { groups = store.groups }
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

    // MARK: Folders (ChatGroup)

    /// Creates a sidebar folder and, from a chat's menu, files that chat in it.
    func createGroup(_ name: String, moving chatId: String? = nil) {
        let clean = ChatGroup.cleanName(name)
        guard let group = store.createGroup(clean.isEmpty ? "New folder" : clean) else { return }
        if let chatId { store.move(chatId, to: group.id) }
        refreshFolders()
    }

    func renameGroup(_ id: String, _ name: String) {
        store.renameGroup(id, name)
        refreshFolders()
    }

    /// Deletes only the folder; its chats move back to the chat list.
    func deleteGroup(_ id: String) {
        store.deleteGroup(id)
        refreshFolders()
    }

    func setGroupCollapsed(_ id: String, _ collapsed: Bool) {
        store.setGroupCollapsed(id, collapsed)
        if groups != store.groups { groups = store.groups }
    }

    /// nil takes the chat out of its folder.
    func moveChat(_ chatId: String, to groupId: String?) {
        if store.move(chatId, to: groupId) { refreshFolders() }
    }

    /// Drop handler for chats dragged onto a folder. False when none of them could move.
    func moveChats(_ chatIds: [String], to groupId: String) -> Bool {
        var moved = false
        for id in chatIds where store.move(id, to: groupId) { moved = true }
        if moved { refreshFolders() }
        return moved
    }

    /// Folder changes edit chats in the store directly, so the open chat picks up its new folder too.
    private func refreshFolders() {
        refreshSummaries()
        if let id = currentId, let chat = store.chats[id], chat.groupId != current?.groupId { current = chat }
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
        let id: String
        if let current = currentId {
            id = current
        } else {
            // Keep whatever was already typed into the new-chat box.
            id = createChat().id
            drafts[id] = drafts["new"]
            drafts["new"] = ""
        }
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
        if settings.memoryEnabled {
            tools.append(RememberTool(save: { [weak self] fact in await self?.rememberFact(fact) ?? "Memory is unavailable." }))
            tools.append(ForgetTool(forget: { [weak self] what in await self?.forgetFacts(what) ?? "Memory is unavailable." }))
            tools.append(SearchPastChatsTool(search: { [weak self] query, chatId in
                await MainActor.run {
                    guard let self else { return "Chat history is unavailable." }
                    return PastChats.search(query, in: Array(self.store.chats.values), excluding: chatId)
                }
            }))
        }
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
            let needVision = Prompt.needsVision(store.chats[chatId]?.messages ?? [])
            let modelId = try await ensureEngine(needVision: needVision)
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
                let system = Prompt.system(chat: chat, settings: settings, toolNames: Set(tools.map(\.name)), skills: Skills.enabled(), memories: memories)
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
                    if model?.thinking == .optional {
                        var kwargs: [String: Any] = ["enable_thinking": thinking]
                        if thinking, let effort = model?.reasoningEffort { kwargs["reasoning_effort"] = effort }
                        body["chat_template_kwargs"] = kwargs
                    }
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
        afterAnswerJobs += 1
        runs[chatId] = nil
        refreshSummaries()
        if store.chats[chatId]?.title == "New chat", store.chats[chatId]?.messages.last?.status == .done { await nameChat(chatId) }
        if store.chats[chatId]?.messages.last?.status == .done { await extractMemories(chatId, messageId) }
        afterAnswerJobs -= 1
    }

    /// Titles and memory checks still running after answers finished (scripts wait on these).
    private var afterAnswerJobs = 0

    /// After an answer, quietly saves lasting facts the user shared (like Claude and ChatGPT do).
    /// Skipped when memory is off, when the model already used `remember` this turn, or when the
    /// message has no personal cues.
    private func extractMemories(_ chatId: String, _ messageId: String) async {
        guard settings.memoryEnabled, case .ready(let id, _) = engineState,
              let chat = store.chats[chatId], let answer = chat.messages.first(where: { $0.id == messageId }),
              let user = chat.messages.last(where: { $0.role == .user }) else { return }
        let usedTool = answer.blocks.contains { if case .tool(let t) = $0 { t.name == "remember" } else { false } }
        // The 2B model saves too much noise (measured: 5 wrong saves in 21 test messages), so it only
        // saves facts when it calls `remember` itself.
        guard !usedTool, (Catalog.model(id)?.quality ?? 0) >= 40, MemoryExtraction.worthChecking(user.text) else { return }
        var body: [String: Any] = ["model": "tarn", "max_tokens": 160, "temperature": 0.1, "stream": false,
                                   "messages": MemoryExtraction.prompt(userText: user.text, known: memories)]
        if Catalog.model(id)?.thinking == .optional { body["chat_template_kwargs"] = ["enable_thinking": false] }
        guard let reply = try? await LLM.complete(baseURL: engine.baseURL, apiKey: engine.apiKey, body: body) else { return }
        var saved: [String] = []
        for fact in MemoryExtraction.parse(reply) {
            guard let clean = MemoryStore.normalize(fact) else { continue }
            let r = MemoryStore.adding(clean, to: memories)
            if r.added {
                memories = r.items
                saved.append(clean)
            }
        }
        guard !saved.isEmpty else { return }
        MemoryStore.save(memories)
        setMessage(chatId, messageId, persist: true) { $0.memorySaved = saved }
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
            #if DEBUG
            // Scripted test runs (-TarnAutoApprove YES) approve after a short pause so the card is visible.
            let auto = UserDefaults.standard.bool(forKey: "TarnAutoApprove")
            if auto { try? await Task.sleep(for: .seconds(1)) }
            #else
            let auto = false
            #endif
            let decision: ApprovalDecision = auto ? .once : await withCheckedContinuation { c in
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

    // MARK: Memory

    func rememberFact(_ raw: String) -> String {
        guard settings.memoryEnabled else { return "Memory is switched off in Settings." }
        guard let fact = MemoryStore.normalize(raw) else { return "Not saved: memories can’t contain passwords, card numbers or other secrets." }
        let r = MemoryStore.adding(fact, to: memories)
        guard r.added else { return "Already remembered." }
        memories = r.items
        MemoryStore.save(memories)
        return "Saved to memory."
    }

    func forgetFacts(_ what: String) -> String {
        let r = MemoryStore.removing(matching: what, from: memories)
        guard r.removed > 0 else { return "No saved memory matched “\(what)”." }
        memories = r.items
        MemoryStore.save(memories)
        return "Forgot \(r.removed) memor\(r.removed == 1 ? "y" : "ies")."
    }

    func deleteMemory(_ id: String) {
        memories.removeAll { $0.id == id }
        MemoryStore.save(memories)
    }

    func clearMemories() {
        memories = []
        MemoryStore.save(memories)
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
            try Backup.export(to: url, chats: chats, groups: store.groups, settings: settings, connectors: connectors, memories: memories)
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
            store.importGroups(contents.groups, replace: replace)
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
            var merged = replace ? [] : memories
            for m in contents.memories.reversed() { merged = MemoryStore.adding(m.text, to: merged).items }
            memories = merged
            MemoryStore.save(memories)
            for a in contents.attachmentFiles {
                try? a.data.write(to: Paths.attachments.appendingPathComponent(a.name))
            }
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
    /// Test hooks for scripted runs (Debug builds only):
    ///   -TarnAutoSend "question" [-TarnAutoFolder /path]  sends one message once the model is ready.
    ///   -TarnTour YES  walks every screen and asks scripts/dev/tour.sh to screenshot each one.
    private func debugAutomation() {
        let d = UserDefaults.standard
        if d.bool(forKey: "TarnTour") {
            Task { await runTour() }
            return
        }
        if let path = d.string(forKey: "TarnScript") {
            Task { await runScript(path) }
            return
        }
        if let mode = d.string(forKey: "TarnDemo") {
            Task { await runDemo(mode) }
            return
        }
        guard let text = d.string(forKey: "TarnAutoSend"), settings.onboarded else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            if let folder = d.string(forKey: "TarnAutoFolder") {
                let c = createChat()
                mutate(c.id) { $0.folder = folder }
            }
            _ = send(text, attachments: [])
        }
    }

    private func tourLog(_ s: String) {
        let url = Paths.data.appendingPathComponent("tour.log")
        let line = Data("\(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Asks the harness for a screenshot and waits until it confirms.
    private func shot(_ name: String, window: String = "main", settle: Double = 1.5) async {
        try? await Task.sleep(for: .seconds(settle))
        tourLog("SHOT \(name) \(window)")
        let ack = Paths.data.appendingPathComponent("tour.ack")
        for _ in 0..<150 {
            if (try? String(contentsOf: ack, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == name { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return condition()
    }

    private func tourSend(_ text: String) async {
        let ok = send(text, attachments: [])
        tourLog("INFO sent=\(ok) \(text.prefix(48))")
        try? await Task.sleep(for: .seconds(0.5))
        _ = await waitUntil(600) { !isAnswering(currentId) }
        if let m = current?.messages.last {
            let tools = m.blocks.compactMap { if case .tool(let t) = $0 { "\(t.name):\(t.status.rawValue)" } else { nil } }
            tourLog("INFO answer status=\(m.status?.rawValue ?? "?") tokens=\(m.tokens ?? 0) ms=\(m.ms ?? 0) tools=\(tools) error=\(m.error ?? "-")")
        }
    }

    struct ScriptStep: Decodable {
        var text: String
        var setTier: String?
        var waitForInstall: Bool?
        var newChat: Bool?
        var attach: [String]?
        var folder: String?
        var thinking: Bool?
        var waitForVision: Bool?
        /// Seconds to keep the window as it is after the answer (for screenshots).
        var hold: Double?
        /// Put this chat in a sidebar folder with this name, creating the folder if needed.
        var intoFolder: String?
    }

    /// Plays chat steps from a JSON file, logging each answer, then quits (tests the quit path too).
    private func runScript(_ path: String) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let steps = try? JSONDecoder().decode([ScriptStep].self, from: data) else {
            tourLog("ERROR bad script"); NSApp.terminate(nil); return
        }
        if activeModelId != nil { _ = await waitUntil(180) { if case .ready = engineState { true } else { false } } }
        for (n, step) in steps.enumerated() {
            if step.newChat ?? true { newChat() }
            if let t = step.thinking { update { $0.thinking = t } }
            if let raw = step.setTier, let tier = Tier(rawValue: raw) {
                let target = picks.pick(tier)?.model.id
                tourLog("INFO tier \(raw) -> \(target ?? "none")")
                setTier(tier)
                if step.waitForInstall == true {
                    let t0 = Date()
                    let ok = await waitUntil(1800) { isInstalled(target) && download.modelId != target }
                    tourLog("INFO installed=\(ok) in \(Int(Date().timeIntervalSince(t0)))s state=\(download)")
                    _ = await waitUntil(240) { if case .ready(let id, _) = engineState { id == target } else { false } }
                    tourLog("INFO engine \(engineState) fit=\(engine.currentConfig?.fitToDevice ?? false)")
                }
            }
            if step.waitForVision == true {
                let ok = await waitUntil(900) { installed.first { $0.id == activeModelId }?.visionFileName != nil }
                tourLog("INFO vision add-on ready=\(ok)")
            }
            if let folder = step.folder {
                let c = createChat()
                mutate(c.id) { $0.folder = folder }
            }
            let files = (step.attach ?? []).compactMap { try? Attachments.read(URL(fileURLWithPath: $0)) }
            tourLog("STEP \(n + 1): \(step.text.prefix(60))")
            _ = send(step.text, attachments: files)
            try? await Task.sleep(for: .seconds(0.5))
            _ = await waitUntil(900) { !isAnswering(currentId) }
            let t0 = Date()
            _ = await waitUntil(120) { afterAnswerJobs == 0 }
            if let m = current?.messages.last {
                let tools = m.blocks.compactMap { if case .tool(let t) = $0 { "\(t.name):\(t.status.rawValue)" } else { nil } }
                let thought = m.blocks.contains { if case .thinking = $0 { true } else { false } }
                tourLog("ANSWER model=\(m.modelId ?? "-") status=\(m.status?.rawValue ?? "?") tools=\(tools) thinking=\(thought) ms=\(m.ms ?? -1) error=\(m.error ?? "-")")
                tourLog("TEXT \(m.visibleText.replacingOccurrences(of: "\n", with: " ").prefix(500))")
                tourLog(String(format: "AFTER %.1fs saved=%@", Date().timeIntervalSince(t0), (m.memorySaved ?? []).description))
            }
            if let name = step.intoFolder, let id = currentId {
                if let g = groups.first(where: { $0.name == name }) { moveChat(id, to: g.id) } else { createGroup(name, moving: id) }
                tourLog("INFO folder \(name) <- \(current?.title ?? id)")
            }
            if let hold = step.hold {
                tourLog("HOLD \(hold)")
                try? await Task.sleep(for: .seconds(hold))
            }
        }
        tourLog("MEMORIES \(memories.map(\.text))")
        tourLog("DONE")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    // MARK: Launch-video demo (Debug only)

    /// Scene marks use wall-clock time so the editor can line them up with the recording.
    private func mark(_ name: String) {
        tourLog(String(format: "MARK %.3f %@", Date().timeIntervalSince1970, name))
    }

    /// Pins the main window to a fixed frame above other windows so the screen recorder can
    /// capture a known rectangle, and reports that rectangle (top-left origin, points).
    private func pinWindowForRecording() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 700 }), let screen = w.screen ?? NSScreen.main else { return }
        let size = NSSize(width: 1280, height: 800)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.level = .floating
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let topY = screen.frame.maxY - (origin.y + size.height)
        tourLog(String(format: "RECT %.0f,%.0f,%.0f,%.0f", origin.x - screen.frame.minX, topY, size.width, size.height))
    }

    /// Types text into the message box at a human pace, then sends it.
    private func demoType(_ text: String, cps: Double = 28) async {
        let key = currentId ?? "new"
        drafts[key] = ""
        for ch in text {
            drafts[key, default: ""].append(ch)
            try? await Task.sleep(for: .seconds(1 / cps))
        }
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func demoAsk(_ text: String, attach: [Attachment] = [], scene: String) async {
        await demoType(text)
        mark("\(scene)-send")
        drafts[currentId ?? "new"] = ""
        _ = send(text, attachments: attach)
        try? await Task.sleep(for: .seconds(0.4))
        _ = await waitUntil(600) { !isAnswering(currentId) }
        mark("\(scene)-done")
        try? await Task.sleep(for: .seconds(2))
    }

    private func runDemo(_ mode: String) async {
        update { $0.theme = .light }
        try? await Task.sleep(for: .seconds(1.5))
        pinWindowForRecording()
        NSCursor.hide()
        defer { NSCursor.unhide() }
        tourLog("WAIT-RECORDER")
        // The harness starts the screen recorder, then writes "go" to tour.ack.
        let ack = Paths.data.appendingPathComponent("tour.ack")
        _ = await waitUntil(30) { (try? String(contentsOf: ack, encoding: .utf8))?.contains("go") == true }
        try? await Task.sleep(for: .seconds(1))
        if mode == "onboarding" {
            mark("welcome"); try? await Task.sleep(for: .seconds(3.5))
            onboardingStep = 1; mark("origin"); try? await Task.sleep(for: .seconds(3))
            onboardingStep = 2; mark("setup")
            // -TarnDemoSetupSeconds N ends the take after N seconds of live download.
            let limit = UserDefaults.standard.double(forKey: "TarnDemoSetupSeconds")
            let ready = await waitUntil(limit > 0 ? limit : 900) { isInstalled(picks.recommended?.model.id) }
            if ready { mark("ready") }
            try? await Task.sleep(for: .seconds(4))
        } else {
            _ = await waitUntil(180) { if case .ready = engineState { true } else { false } }
            newChat(); mark("empty"); try? await Task.sleep(for: .seconds(2.5))
            await demoAsk("Plan a relaxed weekend in Jaipur for two. Keep it short, with a rough budget in rupees.", scene: "chat")
            if let id = currentId { createGroup("Trips", moving: id) }
            newChat()
            await demoAsk("What's the weather in Delhi this weekend? Search the web and keep it brief.", scene: "web")
            if let id = currentId, let trips = groups.first(where: { $0.name == "Trips" }) { moveChat(id, to: trips.id) }
            newChat()
            if let shot = UserDefaults.standard.string(forKey: "TarnDemoImage"), let img = try? Attachments.read(URL(fileURLWithPath: shot)) {
                await demoAsk("Split this bill between the 3 of us, in one line.", attach: [img], scene: "image")
            }
            newChat()
            await demoAsk("I live in Pune and I'm vegetarian. Remember that.", scene: "memory")
            newChat()
            await demoAsk("Suggest a dinner for tonight, in one line.", scene: "recall")
            if let folder = UserDefaults.standard.string(forKey: "TarnDemoFolder") {
                let c = createChat()
                mutate(c.id) { $0.folder = folder }
                await demoType("Read trip.txt and make a packing list file for it.")
                mark("folder-send")
                drafts[c.id] = ""
                _ = send("Read trip.txt and make a packing list file for it.", attachments: [])
                _ = await waitUntil(300) { !approvals.isEmpty }
                mark("approval"); try? await Task.sleep(for: .seconds(3))
                for k in approvals.keys { approve(k, .once) }
                _ = await waitUntil(300) { !isAnswering(currentId) }
                mark("folder-done"); try? await Task.sleep(for: .seconds(2))
            }
        }
        mark("end")
        tourLog("DONE")
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.terminate(nil)
    }

    private func runTour() async {
        update { $0.theme = .light }
        try? await Task.sleep(for: .seconds(1.5))
        if !settings.onboarded {
            await shot("01-welcome")
            onboardingStep = 1
            await shot("02-origin")
            onboardingStep = 2
            await shot("03-setup-start", settle: 5)
            _ = await waitUntil(3600) { (download.progress?.fraction ?? 0) >= 0.4 || isInstalled(picks.recommended?.model.id) }
            await shot("04-setup-downloading", settle: 0.3)
            let ok = await waitUntil(3600) { isInstalled(picks.recommended?.model.id) }
            tourLog("INFO download finished=\(ok) state=\(download)")
            await shot("05-setup-ready")
            finishOnboarding()
        }
        let ready = await waitUntil(180) { if case .ready = engineState { true } else { false } }
        tourLog("INFO engine ready=\(ready) \(engineState)")
        await shot("06-empty-light")
        await tourSend("Plan a relaxed 3-day trip to Jaipur for two people, with a rough budget in rupees.")
        await shot("07-chat-light")
        await tourSend("What's the weather forecast for Delhi this weekend? Search the web.")
        await shot("08-web-search")
        if let imageChat = store.chats.values.first(where: { $0.messages.contains { ($0.attachments ?? []).contains { $0.kind == .image } } }) {
            openChat(imageChat.id)
            await shot("08b-image-chat")
        }

        let folder = Paths.data.appendingPathComponent("demo-folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("Trip: Jaipur, 3 days, 2 people, late November.\n".utf8).write(to: folder.appendingPathComponent("trip.txt"))
        newChat()
        let chat = createChat()
        mutate(chat.id) { $0.folder = folder.path }
        _ = send("Read trip.txt, then create a file called packing-list.md in this folder with a short packing list for that trip.", attachments: [])
        let asked = await waitUntil(300) { !approvals.isEmpty }
        tourLog("INFO approval shown=\(asked)")
        await shot("09-approval")
        for k in approvals.keys { approve(k, .once) }
        _ = await waitUntil(300) { !isAnswering(currentId) }
        tourLog("INFO packing-list written=\(FileManager.default.fileExists(atPath: folder.appendingPathComponent("packing-list.md").path))")
        await shot("10-after-approval")

        memoryAlert = MemoryAlert(critical: false, onLighter: false, engineGB: 6.8)
        await shot("11-memory-alert")
        memoryAlert = nil

        if let first = summaries.last?.id { openChat(first) }
        update { $0.theme = .dark }
        await shot("12-chat-dark")
        newChat()
        await shot("13-empty-dark")

        openSettingsRequest += 1
        settingsTab = "general"
        await shot("14-settings-general-dark", window: "settings")
        settingsTab = "model"
        await shot("15-settings-model-dark", window: "settings")
        settingsTab = "memory"
        await shot("15b-settings-memory-dark", window: "settings")
        update { $0.theme = .light }
        await shot("16-settings-model-light", window: "settings")
        update { $0.theme = .system }
        tourLog("DONE")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
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
