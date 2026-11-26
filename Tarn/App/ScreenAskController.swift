import AppKit
import SwiftUI
import Vision

/// "Ask about your screen": hold ⌥⌘ anywhere, circle something, ask the local vision model.
///
/// Flow: ChordMonitor fires → the display under the pointer is captured once (ScreenCaptureKit)
/// → OverlayView shows that frozen frame and takes the loop → the crop becomes an image
/// attachment in a ScreenAskSession → AskPanelView floats beside it and streams the answer from
/// Tarn's own engine. The vision add-on is loaded only once a capture starts.
@MainActor @Observable
final class ScreenAskController {
    static let panelWidth: CGFloat = 400
    static let panelTall: CGFloat = 470
    static let panelShort: CGFloat = 200
    static let screenRecordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var session = ScreenAskSession()
    var draft = ""
    var notice: String?
    var showPermissions = false
    var focusRequest = 0
    var screenRecording = false
    /// The ⌥⌘ listener is running.
    var listening = false
    private(set) var answeringId: String?

    var answering: Bool { answeringId != nil }
    var canContinue: Bool { !answering && session.messages.contains { $0.role == .assistant && $0.status == .done } }

    struct Timing: Codable {
        var engineMs: Int
        var firstTokenMs: Int?
        var totalMs: Int
        var tokens: Int
        var genMs: Int
    }
    /// How long the last answer took (Debug measurements read this).
    @ObservationIgnored private(set) var lastTiming: Timing?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let chord = ChordMonitor()
    @ObservationIgnored private var overlay: OverlayPanel?
    @ObservationIgnored private var panel: AskPanel?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var capturing = false
    /// Takes a stuck overlay down by itself (see OverlayFailsafe).
    @ObservationIgnored private var failsafe: OverlayFailsafe?
    @ObservationIgnored private var failsafeTimer: Timer?
    @ObservationIgnored private var overlayDrawing = false
    /// Top edge of the panel, kept while it grows from short to tall.
    @ObservationIgnored private var panelVisible: CGRect = .zero
    /// Reopens the main window after "Continue in chat" if the user had closed it.
    @ObservationIgnored var openWindow: OpenWindowAction?
    /// Debug runs show the panel without taking keyboard focus from whatever the user is doing.
    @ObservationIgnored var takeFocus = true
    /// Debug runs never raise macOS permission prompts.
    @ObservationIgnored var mayPrompt = true
    /// Scripted demo: where the "hand" is (global AppKit points), used instead of the mouse
    /// pointer to pick the display and start the ripple. nil in normal use.
    @ObservationIgnored var pointerOverride: CGPoint?
    /// Debug dry runs only: a fixture image used instead of a real capture. Never set in the
    /// final demo path; see runScreenDemo.
    @ObservationIgnored var fixtureFrame: ScreenFrame?
    /// The last circled region, global AppKit points (the demo logs it for the camera).
    @ObservationIgnored private(set) var lastSelection: CGRect?

    init(model: AppModel) {
        self.model = model
        chord.onChord = { [weak self] mode in Task { await self?.begin(mode) } }
    }

    // MARK: Listening and permissions

    func refreshPermissions() {
        screenRecording = ScreenCapture.permitted
    }

    /// Matches the ⌥⌘ listener to Settings. Listening needs no permission; only the capture
    /// needs Screen Recording, which is asked for when the setting is turned on or on first use.
    func apply(enabled: Bool) {
        refreshPermissions()
        guard enabled else {
            chord.stop()
            listening = false
            pollTimer?.invalidate()
            pollTimer = nil
            close()
            return
        }
        // Scripted runs drive the chord themselves and must not react to the person's keyboard.
        guard mayPrompt else { return }
        chord.start()
        listening = true
        if !screenRecording { pollPermissions() }
    }

    /// macOS has no callback for privacy changes; check every two seconds until Screen
    /// Recording is on, so the permission card updates by itself.
    private func pollPermissions() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPermissions()
                if self.screenRecording {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }

    // MARK: Capture

    /// The chord (or the menu command) fired.
    func begin(_ mode: CaptureMode) async {
        guard !capturing, overlay == nil else { return }
        refreshPermissions()
        guard screenRecording || fixtureFrame != nil else {
            if mayPrompt { ScreenCapture.requestPermission() }
            showPermissions = true
            showPanel(near: nil, visible: ScreenCapture.screenUnderPointer()?.visibleFrame ?? .zero)
            return
        }
        let pointer = pointerOverride ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? ScreenCapture.screenUnderPointer() else { return }
        capturing = true
        defer { capturing = false }
        prewarm()
        do {
            let frame: ScreenFrame
            if let fixtureFrame { frame = fixtureFrame } else {
                frame = try await ScreenCapture.capture(screen, excludingWindowNumbers: [panel?.windowNumber].compactMap { $0 })
            }
            showOverlay(frame, mode: mode, pointer: pointer)
        } catch {
            notice = "Tarn couldn’t capture the screen. \(error.localizedDescription)"
            showPanel(near: nil, visible: screen.visibleFrame)
        }
    }

    func showOverlay(_ frame: ScreenFrame, mode: CaptureMode, pointer: CGPoint) {
        let window = OverlayPanel(frame: frame.screenFrame)
        let local = CGPoint(x: pointer.x - frame.screenFrame.minX, y: frame.screenFrame.maxY - pointer.y)
        let view = OverlayView(image: frame.image, pixelsPerPoint: frame.pixelsPerPoint, origin: local, mode: mode,
                               onSelect: { [weak self] rect in self?.selected(rect, in: frame, mode: mode) },
                               onCancel: { [weak self] in self?.dismissOverlay() },
                               onDrawing: { [weak self] drawing in self?.overlayDrawing = drawing })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(frame.screenFrame, display: false)
        window.onEscape = { [weak self] in self?.dismissOverlay() }
        // Scripted runs: clicks pass through to whatever the person at the Mac is doing.
        window.ignoresMouseEvents = !takeFocus
        window.orderFrontRegardless()
        if takeFocus { window.makeKey() }
        overlay = window
        armFailsafe()
    }

    /// Checks once a second whether the overlay has outstayed OverlayFailsafe's limits.
    private func armFailsafe() {
        failsafeTimer?.invalidate()
        overlayDrawing = false
        failsafe = OverlayFailsafe(shownAt: ProcessInfo.processInfo.systemUptime)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let f = self.failsafe else { return }
                if f.shouldDismiss(at: ProcessInfo.processInfo.systemUptime, drawing: self.overlayDrawing) { self.dismissOverlay() }
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        failsafeTimer = t
    }

    private func dismissOverlay() {
        failsafeTimer?.invalidate()
        failsafeTimer = nil
        failsafe = nil
        guard let w = overlay else { return }
        overlay = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { w.orderOut(nil) }
        })
        if let panel, panel.isVisible, takeFocus { panel.makeKey() }
    }

    /// The user finished a loop: keep that part of the frozen frame and open the panel beside it.
    func selected(_ rect: CGRect, in frame: ScreenFrame, mode: CaptureMode) {
        do {
            let capture = try frame.crop(rect, name: "Screen capture")
            if mode == .fresh || session.isEmpty {
                stopAnswer()
                draft = ""
            }
            session.add(capture, mode: mode)
            notice = nil
            showPermissions = false
        } catch {
            notice = error.localizedDescription
        }
        dismissOverlay()
        lastSelection = ScreenGeometry.toGlobal(rect, screenFrame: frame.screenFrame)
        showPanel(near: lastSelection, visible: frame.visibleFrame)
    }

    /// Starts loading the vision add-on while the user draws, so the answer doesn't wait for it.
    private func prewarm() {
        guard let model, let id = model.activeModelId, !model.anyAnswering,
              model.installed.first(where: { $0.id == id })?.visionFileName != nil else { return }
        if model.engine.currentConfig?.visionPath != nil, case .ready = model.engineState { return }
        Task { try? await model.ensureEngine(needVision: true) }
    }

    // MARK: Panel

    func showPanel(near selection: CGRect?, visible: CGRect) {
        let p = panel ?? makePanel()
        panelVisible = visible
        let tall = CGSize(width: Self.panelWidth, height: Self.panelTall)
        // Placed for its tall size, so it never runs off the display when the answer arrives.
        let origin = selection.map { ScreenGeometry.panelOrigin(selection: $0, panel: tall, visible: visible) }
            ?? CGPoint(x: visible.midX - tall.width / 2, y: visible.midY - tall.height / 2)
        let height = currentHeight
        p.setFrame(CGRect(x: origin.x, y: origin.y + tall.height - height, width: tall.width, height: height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        if takeFocus { p.makeKey() }
        focusRequest += 1
    }

    private var currentHeight: CGFloat {
        session.messages.isEmpty && notice == nil && !showPermissions ? Self.panelShort : Self.panelTall
    }

    /// Grows the panel downward from its top edge, staying on the display.
    private func resizePanel() {
        guard let p = panel else { return }
        let h = currentHeight
        guard p.frame.height != h else { return }
        var f = p.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        if panelVisible.height > 0, f.minY < panelVisible.minY { f.origin.y = panelVisible.minY }
        p.setFrame(f, display: true, animate: true)
    }

    private func makePanel() -> AskPanel {
        let p = AskPanel(size: CGSize(width: Self.panelWidth, height: Self.panelShort))
        let host = NSHostingView(rootView: AskPanelView().environment(self))
        host.sizingOptions = []
        p.contentView = host
        p.onEscape = { [weak self] in self?.close() }
        panel = p
        return p
    }

    func close() {
        stopAnswer()
        dismissOverlay()
        panel?.orderOut(nil)
        session = ScreenAskSession()
        draft = ""
        notice = nil
        showPermissions = false
    }

    // MARK: Asking

    func submit() {
        guard !answering, let model else { return }
        guard model.activeModelId != nil else {
            notice = "Tarn is still setting up its AI. This works once the download finishes."
            resizePanel()
            return
        }
        guard session.submit(draft) != nil else { return }
        draft = ""
        notice = nil
        let answer = Message(id: newId(), role: .assistant, createdAt: Date(), status: .streaming)
        session.appendAnswer(answer)
        resizePanel()
        answeringId = answer.id
        runTask = Task { await self.answer(answer.id) }
    }

    func stopAnswer() {
        runTask?.cancel()
    }

    /// Waits for the current answer (Debug batch runs).
    func waitForAnswer() async {
        await runTask?.value
    }

    private func answer(_ id: String) async {
        let t0 = Date()
        var engineReady = t0
        var first: Date?
        var tokens = 0
        var genMs = 0.0
        do {
            guard let model else { return }
            let modelId = try await model.ensureEngine(needVision: Prompt.needsVision(session.messages))
            engineReady = Date()
            try Task.checkCancellation()
            session.updateAnswer(id) { $0.modelId = modelId }
            let cat = Catalog.model(modelId)
            let ctx: Int = if case .ready(_, let c) = model.engineState { c } else { model.contextFor(modelId) }
            let maxOutput = 700
            let past = session.messages.filter { $0.id != id }
            let history = Prompt.history(past, keepFull: 2, attachmentChars: 20_000)
            let messages = Prompt.fit(system: ScreenAskSession.systemPrompt(), history: history, toolsJSONLength: 0, budget: ctx - maxOutput - 256)
            var body: [String: Any] = ["model": "tarn", "messages": messages, "stream": true, "max_tokens": maxOutput, "cache_prompt": true]
            if let s = cat?.sampling {
                body["temperature"] = s.temperature
                body["top_p"] = s.top_p
                body["top_k"] = s.top_k
                body["min_p"] = s.min_p
                if let p = s.presence_penalty { body["presence_penalty"] = p }
            }
            // Quick answers: no thinking for screen questions.
            if cat?.thinking == .optional { body["chat_template_kwargs"] = ["enable_thinking": false] }
            model.engine.markActive()
            for try await chunk in LLM.stream(baseURL: model.engine.baseURL, apiKey: model.engine.apiKey, body: body) {
                try Task.checkCancellation()
                if let e = chunk.error { throw ToolFailure(e) }
                if let c = chunk.content, !c.isEmpty {
                    if first == nil { first = Date() }
                    session.updateAnswer(id) { m in
                        if case .text(let old) = m.blocks.last { m.blocks[m.blocks.count - 1] = .text(old + c) } else { m.blocks.append(.text(c)) }
                    }
                }
                if let n = chunk.predictedTokens { tokens += n; genMs += chunk.predictedMs ?? 0 }
            }
            model.engine.markActive()
            session.updateAnswer(id) { $0.status = .done }
            model.countAnswer()
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            session.updateAnswer(id) { m in
                if cancelled { m.status = .stopped } else {
                    m.status = .error
                    m.error = (error as? ToolFailure)?.message ?? error.localizedDescription
                }
            }
        }
        let total = Date().timeIntervalSince(t0)
        session.updateAnswer(id) { m in
            m.tokens = tokens
            m.ms = Int(genMs > 0 ? genMs : total * 1000)
        }
        lastTiming = Timing(engineMs: Int(engineReady.timeIntervalSince(t0) * 1000), firstTokenMs: first.map { Int($0.timeIntervalSince(t0) * 1000) },
                            totalMs: Int(total * 1000), tokens: tokens, genMs: Int(genMs))
        answeringId = nil
        runTask = nil
    }

    // MARK: Continue in chat

    func continueInChat() {
        guard canContinue, let chat = session.chat(), let model else { return }
        model.importChat(chat)
        close()
        if takeFocus { NSApp.activate() }
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }), w.isVisible || w.isMiniaturized {
            w.deminiaturize(nil)
            if takeFocus { w.makeKeyAndOrderFront(nil) } else { w.orderFront(nil) }
        } else {
            openWindow?(id: "main")
        }
    }
}

#if DEBUG
// MARK: - Debug hooks (scripted runs; nothing here ships in Release)
//
//   -TarnScreenAskBatch file.json   Runs fixture screenshots through the real pipeline after the
//                                   capture step (crop → session → prompt → engine → stream),
//                                   writes screen-ask-results.jsonl to the data folder, quits.
//   -TarnScreenAskShowPanel YES     ...and shows the floating panel while it answers.
//   -TarnScreenAskRender dir -TarnScreenAskFixture image.png
//                                   Renders the overlay's states offscreen to PNGs, quits.
//   -TarnScreenAskOverlayFixture image.png -TarnScreenAskSelect "x,y,w,h" [-TarnScreenAskQuestion q]
//                                   Shows the real overlay with the image as the frozen screen,
//                                   selects the rect as a finished loop would, asks, quits.
//   -TarnScreenAskTrigger fresh     Fires the chord path once (real ScreenCaptureKit) and logs
//                                   permission state; with -TarnScreenAskFeedChord YES it goes
//                                   through ChordMonitor's timer as a held ⌥⌘ would.
extension ScreenAskController {
    struct BatchItem: Decodable {
        var id: String
        var image: String
        var question: String
        /// Region to circle, in points of the fixture (pixels ÷ scale). Whole image if absent.
        var select: [Double]?
        var scale: Double?
        var followUp: String?
    }

    struct BatchResult: Encodable {
        var id: String
        var question: String
        var answer: String
        var status: String
        var error: String?
        var cropPixels: [Int]
        var timing: Timing?
        var followUp: String?
        var followUpAnswer: String?
        var followUpTiming: Timing?
    }

    /// The launch arguments that start one of the hooks below.
    nonisolated static let automationKeys = ["TarnScreenAskBatch", "TarnScreenAskRender", "TarnScreenAskOverlayFixture",
                                             "TarnScreenAskFindTest", "TarnScreenAskProbe", "TarnScreenAskTrigger"]
    /// False for a plain launch. A Debug build opened by a person must then behave like a Release
    /// build: the overlay takes the mouse and Esc, and turning the setting on may raise macOS's
    /// permission prompts. (It used to switch both off on every launch, so a person holding ⌥⌘
    /// got a frozen screen that neither the mouse nor Esc could reach.)
    nonisolated static func automationRequested(_ d: UserDefaults) -> Bool {
        automationKeys.contains { d.object(forKey: $0) != nil }
    }

    /// True when a hook took over the launch.
    func debugAutomation(log: @escaping (String) -> Void) -> Bool {
        let d = UserDefaults.standard
        guard Self.automationRequested(d) else { return false }
        takeFocus = d.bool(forKey: "TarnScreenAskFocus")
        mayPrompt = false
        if let path = d.string(forKey: "TarnScreenAskBatch") {
            Task { await runBatch(path, show: d.bool(forKey: "TarnScreenAskShowPanel"), log: log) }
            return true
        }
        if let dir = d.string(forKey: "TarnScreenAskRender"), let fixture = d.string(forKey: "TarnScreenAskFixture") {
            renderOverlay(fixture: fixture, to: dir, log: log)
            NSApp.terminate(nil)
            return true
        }
        if let fixture = d.string(forKey: "TarnScreenAskOverlayFixture") {
            Task { await runOverlayFixture(fixture, log: log) }
            return true
        }
        if let img = d.string(forKey: "TarnScreenAskFindTest"), let what = d.string(forKey: "TarnScreenAskFindWhat") {
            // Offline check of the demo's aiming: text recognition on an image, then the crop it would circle.
            defer { NSApp.terminate(nil) }
            guard let cg = ScreenCapture.load(URL(fileURLWithPath: img)) else { log("ERROR image"); return true }
            let size = CGSize(width: Double(cg.width) / 2, height: Double(cg.height) / 2)
            let frame = ScreenFrame(image: cg, screenFrame: CGRect(origin: .zero, size: size), visibleFrame: CGRect(origin: .zero, size: size))
            let lines = Self.readText(frame)
            log("INFO read \(lines.count) lines")
            if let r = Self.demoRegion(what, lines), let crop = try? frame.crop(r, name: "find-test"), let url = Attachments.imageURL(crop) {
                log("FOUND \(what) \(NSStringFromRect(r)) crop=\(url.path)")
            } else {
                log("NOTFOUND \(what): \(lines.map(\.text).prefix(30))")
            }
            return true
        }
        if d.bool(forKey: "TarnScreenAskProbe") {
            Task { await runProbe(log: log) }
            return true
        }
        if let raw = d.string(forKey: "TarnScreenAskTrigger") {
            Task { await runTrigger(raw == "append" ? .append : .fresh, feed: d.bool(forKey: "TarnScreenAskFeedChord"), log: log) }
            return true
        }
        return false
    }

    private func waitReady(_ log: (String) -> Void) async -> Bool {
        guard let model, model.activeModelId != nil else { log("ERROR no model installed"); return false }
        let t0 = Date()
        do {
            try await model.ensureEngine(needVision: true)
        } catch {
            log("ERROR engine \(error.localizedDescription)")
            return false
        }
        log(String(format: "INFO engine with vision ready in %.1fs (cold load)", Date().timeIntervalSince(t0)))
        return true
    }

    private func runBatch(_ path: String, show: Bool, log: @escaping (String) -> Void) async {
        defer { NSApp.terminate(nil) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let items = try? JSONDecoder().decode([BatchItem].self, from: data) else { log("ERROR bad batch file"); return }
        guard await waitReady(log) else { return }
        let out = Paths.data.appendingPathComponent("screen-ask-results.jsonl")
        try? Data().write(to: out)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for item in items {
            guard let image = ScreenCapture.load(URL(fileURLWithPath: item.image)) else { log("ERROR can't load \(item.image)"); continue }
            let scale = item.scale ?? 2
            let bounds = CGRect(x: 0, y: 0, width: Double(image.width) / scale, height: Double(image.height) / scale)
            let frame = ScreenFrame(image: image, screenFrame: bounds, visibleFrame: bounds)
            let sel = item.select.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? bounds
            close()
            do {
                session.add(try frame.crop(sel, name: "Screen capture"), mode: .fresh)
            } catch {
                log("ERROR crop \(item.id): \(error.localizedDescription)"); continue
            }
            let crop = ScreenGeometry.cropRect(selection: sel, viewSize: bounds.size, imageSize: CGSize(width: image.width, height: image.height)) ?? .zero
            if show, let screen = NSScreen.main {
                let v = screen.visibleFrame
                showPanel(near: CGRect(x: v.minX + 40, y: v.maxY - 260, width: 300, height: 200), visible: v)
            }
            log("STEP \(item.id): \(item.question)")
            draft = item.question
            submit()
            await waitForAnswer()
            let a = session.messages.last
            var r = BatchResult(id: item.id, question: item.question, answer: a?.visibleText ?? "", status: a?.status?.rawValue ?? "?", error: a?.error,
                                cropPixels: [Int(crop.minX), Int(crop.minY), Int(crop.width), Int(crop.height)], timing: lastTiming)
            log("ANSWER \(item.id) ttft=\(lastTiming?.firstTokenMs ?? -1)ms total=\(lastTiming?.totalMs ?? -1)ms tokens=\(lastTiming?.tokens ?? 0) \(r.answer.replacingOccurrences(of: "\n", with: " ").prefix(300))")
            if show { snapshot("panel-\(item.id)", log: log) }
            if let f = item.followUp {
                draft = f
                submit()
                await waitForAnswer()
                r.followUp = f
                r.followUpAnswer = session.messages.last?.visibleText
                r.followUpTiming = lastTiming
                log("FOLLOWUP \(item.id) ttft=\(lastTiming?.firstTokenMs ?? -1)ms \(r.followUpAnswer?.replacingOccurrences(of: "\n", with: " ").prefix(200) ?? "")")
            }
            if let line = try? enc.encode(r), let h = try? FileHandle(forWritingTo: out) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line + Data("\n".utf8))
                try? h.close()
            }
        }
        close()
        log("DONE")
        try? await Task.sleep(for: .seconds(0.5))
    }

    private func renderOverlay(fixture: String, to dir: String, log: (String) -> Void) {
        guard let image = ScreenCapture.load(URL(fileURLWithPath: fixture)) else { log("ERROR fixture"); return }
        let size = CGSize(width: Double(image.width) / 2, height: Double(image.height) / 2)
        let loop: [CGPoint] = (0...40).map { i in
            let t = Double(i) / 40 * 2 * .pi * 1.06
            return CGPoint(x: size.width * 0.5 + cos(t) * size.width * 0.17 + sin(t * 3) * 6, y: size.height * 0.45 + sin(t) * size.height * 0.15)
        }
        let states: [(String, OverlayView.Preset)] = [
            ("1-ripple", .init(points: [], selection: nil, ripple: 0.22)),
            ("2-ready", .init(points: [], selection: nil, ripple: nil)),
            ("3-drawing", .init(points: Array(loop.prefix(30)), selection: nil, ripple: nil)),
            ("4-selected", .init(points: [], selection: ScreenGeometry.selection(from: loop, in: size), ripple: nil)),
        ]
        for (name, preset) in states {
            let view = OverlayView(image: image, pixelsPerPoint: 2, origin: CGPoint(x: size.width * 0.5, y: size.height * 0.45), mode: .fresh,
                                   onSelect: { _ in }, onCancel: {}, preset: preset)
                .frame(width: size.width, height: size.height)
            let r = ImageRenderer(content: view)
            r.scale = 1
            guard let cg = r.cgImage, let png = try? ScreenCapture.png(cg) else { log("ERROR render \(name)"); continue }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("overlay-\(name).png"))
            log("INFO rendered overlay-\(name).png")
        }
    }

    private func runOverlayFixture(_ fixture: String, log: @escaping (String) -> Void) async {
        defer { NSApp.terminate(nil) }
        let d = UserDefaults.standard
        guard let image = ScreenCapture.load(URL(fileURLWithPath: fixture)), let screen = NSScreen.main else { log("ERROR fixture"); return }
        guard await waitReady(log) else { return }
        // The fixture stands in for the display: drawn at the display's size, like a capture.
        let frame = ScreenFrame(image: image, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let parts = (d.string(forKey: "TarnScreenAskSelect") ?? "").split(separator: ",").compactMap { Double($0) }
        let sel = parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            : CGRect(x: screen.frame.width * 0.3, y: screen.frame.height * 0.3, width: 300, height: 200)
        showOverlay(frame, mode: .fresh, pointer: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
        try? await Task.sleep(for: .seconds(0.9))
        snapshot("overlay-live", window: overlay, log: log)
        try? await Task.sleep(for: .seconds(1.6))
        selected(sel, in: frame, mode: .fresh)
        try? await Task.sleep(for: .seconds(0.6))
        log("INFO panel frame=\(panel.map { NSStringFromRect($0.frame) } ?? "-") selection(global)=\(NSStringFromRect(ScreenGeometry.toGlobal(sel, screenFrame: frame.screenFrame)))")
        log("INFO capture=\(session.captures.first.map { Attachments.imageURL($0)?.path ?? "-" } ?? "none")")
        draft = d.string(forKey: "TarnScreenAskQuestion") ?? ""
        submit()
        await waitForAnswer()
        log("ANSWER ttft=\(lastTiming?.firstTokenMs ?? -1)ms total=\(lastTiming?.totalMs ?? -1)ms \(session.messages.last?.visibleText.replacingOccurrences(of: "\n", with: " ").prefix(300) ?? "")")
        snapshot("panel-answer", log: log)
        // ⇧⌥⌘: a second capture joins the same conversation and rides on the next question.
        let p2 = (d.string(forKey: "TarnScreenAskAppendSelect") ?? "").split(separator: ",").compactMap { Double($0) }
        if p2.count == 4 {
            let sel2 = CGRect(x: p2[0], y: p2[1], width: p2[2], height: p2[3])
            showOverlay(frame, mode: .append, pointer: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            try? await Task.sleep(for: .seconds(1))
            selected(sel2, in: frame, mode: .append)
            try? await Task.sleep(for: .seconds(0.5))
            log("INFO after append: captures=\(session.captures.count) pending=\(session.pending.count) messages=\(session.messages.count) panel=\(panel.map { NSStringFromRect($0.frame) } ?? "-")")
            draft = d.string(forKey: "TarnScreenAskAppendQuestion") ?? ""
            submit()
            await waitForAnswer()
            let sent = Prompt.history(session.messages.filter { $0.role == .user || $0.status == .done }).filter { ($0["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true }.count
            log("ANSWER2 images-in-prompt=\(sent) ttft=\(lastTiming?.firstTokenMs ?? -1)ms total=\(lastTiming?.totalMs ?? -1)ms \(session.messages.last?.visibleText.replacingOccurrences(of: "\n", with: " ").prefix(300) ?? "")")
            snapshot("panel-append", log: log)
        }
        if d.bool(forKey: "TarnScreenAskContinue") {
            let before = model?.summaries.count ?? 0
            let mainWindow = { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible } }
            log("INFO main window id=\(mainWindow()?.identifier?.rawValue ?? "none")")
            if d.bool(forKey: "TarnScreenAskCloseMain") {
                model?.update { $0.screenAsk = true } // keeps Tarn running with no window (no tap in scripted runs)
                mainWindow()?.close()
                try? await Task.sleep(for: .seconds(1))
                log("INFO closed main window; app still running, visible main window=\(mainWindow() != nil)")
            }
            continueInChat()
            try? await Task.sleep(for: .seconds(1.5))
            log("INFO continue-in-chat chats \(before) -> \(model?.summaries.count ?? 0), open=\(model?.current?.title ?? "-") messages=\(model?.current?.messages.count ?? 0) images=\(model?.current?.messages.compactMap(\.attachments).count ?? 0) panelVisible=\(panel?.isVisible ?? false) mainWindowVisible=\(mainWindow() != nil)")
            if d.bool(forKey: "TarnScreenAskCloseMain") { model?.update { $0.screenAsk = false } }
            snapshot("chat-after-continue", window: NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }, log: log)
        }
        log("DONE")
    }

    /// Draws a window's content in-process to data/shots/<name>.png. Unlike screencapture this
    /// needs no Screen Recording permission (Liquid Glass may draw flatter than on screen).
    private func snapshot(_ name: String, window: NSWindow? = nil, log: (String) -> Void) {
        guard let view = (window ?? panel)?.contentView else { log("INFO no window for \(name)"); return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = Paths.data.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        log("SHOT \(name)")
    }

    private func runTrigger(_ mode: CaptureMode, feed: Bool, log: @escaping (String) -> Void) async {
        defer { NSApp.terminate(nil) }
        refreshPermissions()
        log("INFO permissions screenRecording=\(screenRecording)")
        if feed {
            var fired: CaptureMode?
            chord.onChord = { m in fired = m }
            chord.feed([.option, .command])
            try? await Task.sleep(for: .seconds(0.2))
            log("INFO after 0.2s fired=\(String(describing: fired))")
            try? await Task.sleep(for: .seconds(0.3))
            log("INFO after 0.5s fired=\(String(describing: fired))")
            chord.feed([])
            chord.onChord = { [weak self] m in Task { await self?.begin(m) } }
            guard let m = fired else { return }
            await begin(m)
        } else {
            await begin(mode)
        }
        try? await Task.sleep(for: .seconds(0.8))
        log("INFO overlayShown=\(overlay != nil) panelVisible=\(panel?.isVisible ?? false) showPermissions=\(showPermissions) notice=\(notice ?? "-")")
        snapshot("trigger-result", log: log)
        log("DONE")
    }
}
#endif

#if DEBUG
// MARK: - Probe and the scripted screen demo (-TarnDemo screen)

extension ScreenAskController {
    /// -TarnScreenAskProbe YES: does this process have Screen Recording, and does a real capture
    /// work? Logs sizes only (never saves the picture), then quits.
    private func runProbe(log: @escaping (String) -> Void) async {
        defer { NSApp.terminate(nil) }
        let ok = CGPreflightScreenCaptureAccess()
        log("INFO probe screenRecording=\(ok) screens=\(NSScreen.screens.map { NSStringFromRect($0.frame) })")
        guard ok, let screen = NSScreen.screens.first else { log("DONE"); return }
        do {
            let f = try await ScreenCapture.capture(screen, excludingWindowNumbers: [])
            log("INFO probe capture ok \(f.image.width)x\(f.image.height) px, \(String(format: "%.2f", f.pixelsPerPoint)) px/pt")
        } catch {
            log("INFO probe capture failed: \(error.localizedDescription)")
        }
        log("DONE")
    }

    /// The demo for video/make_screen_demo.sh: everything real (ScreenCaptureKit capture, the
    /// overlay, the model's streamed answers, Continue in chat). Only the hand is scripted: the
    /// ⌥⌘ hold goes through ChordMonitor's state machine, the loop is mouse events sent to the
    /// overlay window (the same DragGesture the mouse drives), and the question is typed into
    /// the box letter by letter.
    ///
    ///   -TarnScreenDemoRegion1 "App Name|x,y,w,h"   what to circle first, in points from the top
    ///   -TarnScreenDemoRegion2 "App Name|x,y,w,h"   left of that app's front window
    ///   -TarnScreenDemoQ1 / -TarnScreenDemoQ2       the questions
    ///   -TarnScreenDemoFixture image.png            DRY RUN ONLY: a fixture instead of the screen;
    ///                                               regions are then "fixture|x,y,w,h" in screen points
    func runScreenDemo(model: AppModel, log: @escaping (String) -> Void, mark: @escaping (String) -> Void) async {
        let d = UserDefaults.standard
        mayPrompt = false
        takeFocus = true
        func fail(_ code: String, _ message: String) {
            log("ERROR \(code) \(message)")
            NSApp.terminate(nil)
        }
        let dryRun = d.string(forKey: "TarnScreenDemoFixture")
        let permitted = CGPreflightScreenCaptureAccess()
        log("INFO screenRecording=\(permitted) dryRun=\(dryRun != nil)")
        if let dryRun {
            guard let image = ScreenCapture.load(URL(fileURLWithPath: dryRun)), let screen = NSScreen.screens.first else { return fail("FIXTURE", "can't load \(dryRun)") }
            fixtureFrame = ScreenFrame(image: image, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
            log("INFO DRY RUN: a fixture image stands in for the screen. This run is for testing only.")
        } else if !permitted {
            // Never fall back to a fixture: the demo must show the real capture.
            return fail("NO-SCREEN-RECORDING", "This Tarn build has no Screen Recording permission, so it can't capture what you circle.")
        }
        guard await waitReady(log) else { return fail("ENGINE", "the AI didn't start") }

        // Find what to circle. Real runs aim by reading the screen (on-device text recognition on
        // a real capture), so the loop lands on the content wherever the app put its window.
        guard let main = NSScreen.screens.first else { return fail("SCREEN", "no display") }
        func spec(_ key: String) -> (app: String, what: String)? {
            let parts = (d.string(forKey: key) ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        func region(_ s: (app: String, what: String)) async -> CGRect? {
            if s.app == "fixture" {
                let n = s.what.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return n.count == 4 ? ScreenGeometry.toGlobal(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), screenFrame: main.frame) : nil
            }
            guard let win = Self.frontWindow(ofApp: s.app) else { log("INFO no window for \(s.app)"); return nil }
            guard let shot = try? await ScreenCapture.capture(main, excludingWindowNumbers: [panel?.windowNumber].compactMap { $0 }) else { return nil }
            let lines = Self.readText(shot).filter { win.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            guard let topLeft = Self.demoRegion(s.what, lines) else {
                log("INFO couldn't find the \(s.what) text in \(s.app); read: \(lines.map(\.text).prefix(40))")
                return nil
            }
            return CGRect(x: topLeft.minX, y: main.frame.maxY - topLeft.maxY, width: topLeft.width, height: topLeft.height)
        }
        guard let s1 = spec("TarnScreenDemoRegion1"), let s2 = spec("TarnScreenDemoRegion2") else { return fail("REGIONS", "TarnScreenDemoRegion1/2 missing") }
        let q1 = d.string(forKey: "TarnScreenDemoQ1") ?? "How much free space do I have?"
        let q2 = d.string(forKey: "TarnScreenDemoQ2") ?? "Is that enough to install this?"
        func box(_ name: String, _ r: CGRect?) {
            guard let r else { return }
            log(String(format: "BOX %@ %.1f %.1f %.1f %.1f", name, r.minX - main.frame.minX, main.frame.maxY - r.maxY, r.width, r.height))
        }
        box("screen", main.frame)

        // Tarn keeps running with no window; its own window comes back with Continue in chat.
        model.update { $0.screenAsk = true; $0.theme = .system }
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true { w.close() }
        if dryRun == nil { await bringForward(s1.app, log: log) }
        guard let first = await region(s1) else { return fail("REGION1", "couldn't find what to circle in \(s1.app)") }
        box("target1", first)

        // The recorder starts, then writes "go".
        log("WAIT-RECORDER")
        let ack = Paths.data.appendingPathComponent("tour.ack")
        let started = Date()
        while Date().timeIntervalSince(started) < 30, (try? String(contentsOf: ack, encoding: .utf8))?.contains("go") != true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        mark("start")
        try? await Task.sleep(for: .seconds(2.2))

        for (n, (question, mode)) in [(q1, CaptureMode.fresh), (q2, CaptureMode.append)].enumerated() {
            let beat = n + 1
            var target = first
            if beat == 2 {
                // The hand brings the second app forward (as a click on its window would), then aims.
                if dryRun == nil, s2.app != s1.app {
                    mark("raise2")
                    await bringForward(s2.app, log: log)
                    try? await Task.sleep(for: .seconds(0.8))
                }
                guard let r = await region(s2) else { return fail("REGION2", "couldn't find what to circle in \(s2.app)") }
                target = r
                box("target2", r)
            }
            let loop = Self.loopPath(around: target)
            pointerOverride = loop.first
            mark("chord\(beat)")
            chord.feed(mode == .append ? [.shift, .option, .command] : [.option, .command])
            guard await until(4, { self.overlay != nil }) else { return fail("OVERLAY", "the overlay didn't open (beat \(beat))") }
            mark("overlay\(beat)")
            chord.feed([]) // keys up once the screen has frozen
            try? await Task.sleep(for: .seconds(0.9))
            mark("draw\(beat)")
            await drawLoop(loop, seconds: 1.1)
            guard await until(3, { self.overlay == nil && self.panel?.isVisible == true }) else { return fail("PANEL", "no panel after the loop (beat \(beat))") }
            mark("panel\(beat)")
            box("sel\(beat)", lastSelection)
            try? await Task.sleep(for: .seconds(0.6))
            mark("type\(beat)")
            for ch in question {
                draft.append(ch)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 38...62)))
            }
            try? await Task.sleep(for: .seconds(0.4))
            mark("send\(beat)")
            submit()
            _ = await until(60, { self.session.messages.last.map { $0.role == .assistant && !$0.visibleText.isEmpty } ?? false })
            mark("first\(beat)")
            await waitForAnswer()
            mark("done\(beat)")
            let answer = session.messages.last
            log("ANSWER\(beat) status=\(answer?.status?.rawValue ?? "?") ttft=\(lastTiming?.firstTokenMs ?? -1)ms total=\(lastTiming?.totalMs ?? -1)ms tokens=\(lastTiming?.tokens ?? 0)")
            log("TEXT\(beat) \(answer?.visibleText.replacingOccurrences(of: "\n", with: " ⏎ ") ?? "")")
            box("panel\(beat)", panel?.frame)
            if answer?.status != .done { return fail("ANSWER", "answer \(beat) didn't finish (\(answer?.error ?? "no error"))") }
            try? await Task.sleep(for: .seconds(beat == 1 ? 2.4 : 2.0))
        }

        mark("continue")
        continueInChat()
        guard await until(4, { NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible } }) else {
            return fail("CHAT", "the chat window didn't open")
        }
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            let v = main.visibleFrame
            let size = CGSize(width: min(1180, v.width - 80), height: min(780, v.height - 40))
            w.setFrame(CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
            // A real click on Continue in chat activates Tarn; a scripted one can't (macOS refuses to
            // activate an app without a user event), so float the window above the others for the
            // recording, as pinWindowForRecording does for the main demo.
            w.level = .floating
            w.orderFrontRegardless()
            box("chat", w.frame)
        }
        mark("chat")
        log("INFO chat=\(model.current?.title ?? "-") messages=\(model.current?.messages.count ?? 0)")
        try? await Task.sleep(for: .seconds(4.5))
        mark("end")
        model.update { $0.screenAsk = false }
        log("DONE")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    /// Brings an app to the front the way the Dock or a click would, through LaunchServices
    /// (`open -a`), which needs no Accessibility or Automation permission.
    private func bringForward(_ app: String, log: (String) -> Void) async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        try? p.run()
        p.waitUntilExit()
        _ = await until(3) { NSWorkspace.shared.frontmostApplication?.localizedName == app }
        log("INFO frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
    }

    /// Text on a real capture, with each line's box in global points from the top left.
    static func readText(_ frame: ScreenFrame) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])
        let w = frame.screenFrame.width, h = frame.screenFrame.height
        return (request.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return (t, CGRect(x: frame.screenFrame.minX + b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }

    /// The demo's two targets, found by their text. Top-left global points.
    ///   disk:  Disk Utility's volume header through the Used / Other Volumes / Free figures
    ///   guide: the install guide's "BEFORE YOU INSTALL" box
    static func demoRegion(_ what: String, _ lines: [(text: String, box: CGRect)]) -> CGRect? {
        // Legends come back as "• Free" or "O Free" (the swatch read as a letter): for exact
        // matches, accept a short line whose last word is the label.
        func isLabel(_ t: String, _ s: String) -> Bool {
            let words = t.split(whereSeparator: \.isWhitespace)
            return words.count <= 2 && words.last.map(String.init) == s
        }
        func find(_ s: String, exact: Bool = false) -> [CGRect] {
            lines.filter { exact ? isLabel($0.text, s) : $0.text.localizedCaseInsensitiveContains(s) }.map(\.box)
        }
        switch what {
        case "disk":
            // The big header (tallest "Macintosh HD"), then the "Free" legend and the figure under it.
            guard let header = find("Macintosh HD").max(by: { $0.height < $1.height }),
                  let free = find("Free", exact: true).first else { return nil }
            let figures = lines.filter { $0.text.contains("GB") && $0.box.minY > free.maxY - 2 && $0.box.minY < free.maxY + 40 }.map(\.box)
            guard let freeValue = figures.min(by: { abs($0.minX - free.minX) < abs($1.minX - free.minX) }) else { return nil }
            let capacity = lines.filter { $0.text.contains("GB") && abs($0.box.midY - header.midY) < 40 && $0.box.minX > header.maxX }.map(\.box)
            let right = max(freeValue.maxX, free.maxX + 60, capacity.map(\.maxX).max() ?? 0) + 10
            // From the volume icon (left of the header) to the figures under the legend.
            return CGRect(x: header.minX - 82, y: header.minY - 14, width: right - (header.minX - 82), height: freeValue.maxY + 8 - (header.minY - 14))
        case "guide":
            guard let top = find("BEFORE YOU INSTALL").first, let bottom = find("Apple silicon").first else { return nil }
            return CGRect(x: top.minX - 18, y: top.minY - 14, width: bottom.maxX + 24 - (top.minX - 18), height: bottom.maxY + 14 - (top.minY - 14))
        default:
            return nil
        }
    }

    private func until(_ seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    /// The front on-screen window of an app, in global points from the top left of the main display.
    static func frontWindow(ofApp name: String) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == name && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: Double], let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
               rect.width > 200, rect.height > 150 { return rect }
        }
        return nil
    }

    /// A hand-drawn loop around a region: a rounded, slightly uneven lap that starts at the top
    /// left, runs clockwise and overshoots its start a little. Global AppKit points.
    static func loopPath(around r: CGRect, steps: Int = 96) -> [CGPoint] {
        let c = CGPoint(x: r.midX, y: r.midY)
        let a = r.width / 2 + 8, b = r.height / 2 + 8
        let start = 0.75 * Double.pi // top left, going clockwise (y up in AppKit)
        return (0...steps).map { i in
            let u = Double(i) / Double(steps)
            let t = start - u * 2 * Double.pi * 1.08
            let wobble = 1 + 0.025 * sin(u * 9) + 0.02 * u
            // A squircle keeps the loop close to the rectangle, so the crop stays tight.
            let cx = cos(t), sy = sin(t)
            let x = a * wobble * (cx < 0 ? -1 : 1) * pow(abs(cx), 0.55)
            let y = b * wobble * (sy < 0 ? -1 : 1) * pow(abs(sy), 0.55)
            return CGPoint(x: c.x + x, y: c.y + y)
        }
    }

    /// Mouse down, drags and up sent to the overlay window, so the loop goes through the same
    /// SwiftUI DragGesture as a real mouse.
    private func drawLoop(_ points: [CGPoint], seconds: Double) async {
        guard let w = overlay, let first = points.first, let last = points.last else { return }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let e = event(.leftMouseDown, first) { w.sendEvent(e) }
        let step = seconds / Double(max(1, points.count - 1))
        for p in points.dropFirst() {
            try? await Task.sleep(for: .seconds(step))
            if let e = event(.leftMouseDragged, p) { w.sendEvent(e) }
        }
        if let e = event(.leftMouseUp, last) { w.sendEvent(e) }
    }
}
#endif
