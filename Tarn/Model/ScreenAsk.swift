import CoreGraphics
import Foundation

// Pure logic behind "Ask about your screen" (hold ⌥⌘, circle something, ask). No AppKit here,
// so every rule is unit-tested in TarnTests.

/// Whether a capture starts a new floating conversation or joins the open one.
enum CaptureMode: Equatable { case fresh, append }

/// Detects a modifier-only chord: ⌥⌘ (fresh) or ⇧⌥⌘ (append) held on their own for `hold`
/// seconds. Ordinary shortcuts such as ⌥⌘Esc or ⌥⌘-click never fire it: any key or mouse press
/// while the modifiers are down cancels the chord until ⌥ and ⌘ are both released.
struct ChordDetector: Equatable {
    struct Mods: OptionSet, Hashable {
        let rawValue: Int
        static let shift = Mods(rawValue: 1)
        static let control = Mods(rawValue: 2)
        static let option = Mods(rawValue: 4)
        static let command = Mods(rawValue: 8)
    }

    enum State: Equatable {
        case idle
        case armed(since: TimeInterval, mode: CaptureMode)
        /// Fired, or spoiled by another key, mouse press or modifier: wait until ⌥ and ⌘ are up.
        case blocked
    }

    /// Long enough that ⌥⌘ followed by a key (typically under 250 ms) doesn't fire, short enough
    /// to feel immediate.
    var hold: TimeInterval = 0.35
    private(set) var state: State = .idle

    static func mode(for m: Mods) -> CaptureMode? {
        switch m {
        case [.option, .command]: .fresh
        case [.option, .command, .shift]: .append
        default: nil
        }
    }

    /// When the armed chord fires, so the caller can schedule a `tick` for that moment.
    var deadline: TimeInterval? {
        if case .armed(let since, _) = state { return since + hold }
        return nil
    }

    mutating func flagsChanged(_ m: Mods, at t: TimeInterval) {
        let chord = Self.mode(for: m)
        switch state {
        case .idle:
            if let chord { state = .armed(since: t, mode: chord) }
        case .armed(_, let mode):
            if let chord {
                // ⌥⌘ then ⇧ (or the reverse): restart the timer so the final combination decides.
                if chord != mode { state = .armed(since: t, mode: chord) }
            } else if m.contains(.control) {
                state = .blocked // ⌃⌥⌘ is a different shortcut family
            } else {
                state = .idle // let go of ⌥ or ⌘ before the hold time: nothing happens
            }
        case .blocked:
            if m.isDisjoint(with: [.option, .command]) { state = .idle }
        }
    }

    mutating func keyDown(at t: TimeInterval) {
        if case .armed = state { state = .blocked }
    }

    mutating func mouseDown(at t: TimeInterval) {
        if case .armed = state { state = .blocked }
    }

    /// Returns the mode when the chord has been held long enough. Fires once per press.
    mutating func tick(at t: TimeInterval) -> CaptureMode? {
        guard case .armed(let since, let mode) = state, t - since >= hold - 0.0005 else { return nil }
        state = .blocked
        return mode
    }

    /// When the current ⌥⌘ (or ⇧⌥⌘) combination formed, while it's waiting out the hold.
    var armedSince: TimeInterval? {
        if case .armed(let since, _) = state { return since }
        return nil
    }
}

/// Feeds ChordDetector from polled samples instead of an event tap, so watching for ⌥⌘ needs no
/// macOS permission. Each sample carries the modifier keys held now and when the newest key
/// press, mouse press and modifier change happened (macOS reports those times to any app,
/// never which key). That is enough to time the hold from the real press, and to cancel it when
/// any key or button goes down after ⌥⌘ formed, even between two polls.
struct ChordPoller: Equatable {
    struct Sample: Equatable {
        var now: TimeInterval
        var mods: ChordDetector.Mods
        /// When the newest key, mouse button and modifier change went down (same clock as `now`).
        var keyAt: TimeInterval
        var mouseAt: TimeInterval
        var flagsAt: TimeInterval
    }

    private(set) var detector = ChordDetector()
    private var mods: ChordDetector.Mods = []
    private var lastPoll: TimeInterval?
    /// Keys and clicks from this moment on cancel the armed chord.
    private var cancelFrom: TimeInterval?

    /// Poll fast while ⌥ or ⌘ is down (the hold is being timed), slowly otherwise.
    var wantsFastPolling: Bool { !mods.isDisjoint(with: [.option, .command]) }

    /// Returns the mode when the chord fires.
    mutating func update(_ s: Sample) -> CaptureMode? {
        if s.mods != mods {
            // The change happened at flagsAt. If that time is older than the previous poll (the
            // timer missed it or isn't readable), use the earliest moment the change could have
            // happened: right after the previous poll. Either way it's never in the future.
            let before = detector.armedSince
            let at = min(s.now, max(s.flagsAt, lastPoll ?? s.flagsAt))
            detector.flagsChanged(s.mods, at: at)
            mods = s.mods
            if let since = detector.armedSince, since != before {
                // A key in the same poll window as the press also cancels: a fast ⌥⌘Esc can land
                // before this poll, and the modifier timer isn't trusted to order the two.
                cancelFrom = min(since, lastPoll ?? since)
            }
        }
        if let since = detector.armedSince {
            // Anything pressed after ⌥⌘ formed (⌥⌘Esc, ⌥⌘-click) is an ordinary shortcut.
            let from = cancelFrom ?? since
            if s.keyAt >= from { detector.keyDown(at: s.keyAt) }
            if s.mouseAt >= from { detector.mouseDown(at: s.mouseAt) }
        }
        lastPoll = s.now
        return detector.tick(at: s.now)
    }
}

/// Takes the full-screen overlay down by itself if nobody finishes a selection, so a frozen
/// screen can never trap the person (for example if the overlay stops getting the mouse or Esc).
struct OverlayFailsafe: Equatable {
    /// No finished selection after this long: the overlay goes away.
    static let timeout: TimeInterval = 30
    /// A stroke still in progress gets more time, but a stroke that never ends (a lost mouse-up)
    /// can't hold the screen past this.
    static let hardLimit: TimeInterval = 45

    let shownAt: TimeInterval

    func shouldDismiss(at now: TimeInterval, drawing: Bool) -> Bool {
        let age = now - shownAt
        return age >= Self.hardLimit || (age >= Self.timeout && !drawing)
    }
}

/// Selection-to-crop geometry. View coordinates are the overlay's (points, top-left origin, one
/// overlay per display); AppKit screen coordinates are global (points, bottom-left origin).
enum ScreenGeometry {
    /// Smallest selection treated as a real one (points); shorter strokes are stray clicks.
    static let minSide: CGFloat = 12
    /// Context kept around the circled region (points), so a circled icon keeps its label.
    static let padding: CGFloat = 10

    static func boundingBox(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The region a loop or drag selects: its bounding box plus padding, kept on the display.
    /// nil when the stroke was too small to mean anything.
    static func selection(from points: [CGPoint], in bounds: CGSize, padding: CGFloat = padding) -> CGRect? {
        guard let box = boundingBox(points), box.width >= minSide || box.height >= minSide else { return nil }
        let area = CGRect(origin: .zero, size: bounds)
        let padded = box.insetBy(dx: -padding, dy: -padding).intersection(area)
        return padded.isNull || padded.width < 1 || padded.height < 1 ? nil : padded
    }

    /// Pixel rectangle in the captured display image for a selection in view points. Uses the
    /// image's real pixels-per-point (2 on Retina, other values in scaled modes), not an assumed
    /// scale, and snaps outward to whole pixels.
    static func cropRect(selection: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let px = CGRect(x: selection.minX * sx, y: selection.minY * sy, width: selection.width * sx, height: selection.height * sy)
        let snapped = CGRect(x: floor(px.minX), y: floor(px.minY), width: ceil(px.maxX) - floor(px.minX), height: ceil(px.maxY) - floor(px.minY))
        let clipped = snapped.intersection(CGRect(origin: .zero, size: imageSize))
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? nil : clipped
    }

    /// A rectangle in one display's overlay (top-left origin) in global AppKit coordinates.
    static func toGlobal(_ local: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + local.minX, y: screenFrame.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// Where the floating panel goes: beside the selection (right, then left), else below or
    /// above it, always inside the display's visible area. When every spot would cover part of
    /// the selection (a big one), the spot covering least of it wins. Global AppKit coordinates.
    static func panelOrigin(selection s: CGRect, panel: CGSize, visible v: CGRect, gap: CGFloat = 14) -> CGPoint {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, v.minX), max(v.minX, v.maxX - panel.width)),
                    y: min(max(p.y, v.minY), max(v.minY, v.maxY - panel.height)))
        }
        func covered(_ o: CGPoint) -> CGFloat {
            let r = CGRect(origin: o, size: panel).intersection(s)
            return r.isNull ? 0 : r.width * r.height
        }
        let top = s.maxY - panel.height
        let spots = [
            CGPoint(x: s.maxX + gap, y: top),
            CGPoint(x: s.minX - gap - panel.width, y: top),
            CGPoint(x: s.minX, y: s.minY - gap - panel.height),
            CGPoint(x: s.minX, y: s.maxY + gap),
        ].map(clamp)
        // min(by:) keeps the earliest of equal spots, so the preference order breaks ties.
        return spots.min { covered($0) < covered($1) } ?? clamp(s.origin)
    }
}

/// The floating conversation. Its messages are ordinary chat messages, so "Continue in chat"
/// moves them into a normal Tarn chat unchanged.
///
/// Context rules:
/// - A fresh capture (⌥⌘) clears the conversation and waits for a question about it.
/// - An appended capture (⇧⌥⌘) keeps the conversation; new captures ride on the next question.
/// - Return on an empty box asks "What is this?".
/// - Follow-up questions without a new capture still see the earlier images (the prompt keeps
///   pixels for the two most recent messages with images, like normal chats).
struct ScreenAskSession: Equatable {
    static let defaultQuestion = "What is this?"
    static let maxPendingCaptures = 4

    private(set) var messages: [Message] = []
    /// Captures waiting for the next question.
    private(set) var pending: [Attachment] = []

    var isEmpty: Bool { messages.isEmpty && pending.isEmpty }
    /// Thumbnails shown in the panel: every capture in the conversation, oldest first.
    var captures: [Attachment] { messages.flatMap { $0.attachments ?? [] } + pending }

    mutating func add(_ capture: Attachment, mode: CaptureMode) {
        if mode == .fresh {
            messages = []
            pending = []
        }
        pending.append(capture)
        if pending.count > Self.maxPendingCaptures { pending.removeFirst(pending.count - Self.maxPendingCaptures) }
    }

    /// Turns the typed text and any pending captures into a user message. nil when there is
    /// nothing to ask about (no capture yet and no earlier exchange).
    mutating func submit(_ typed: String, now: Date = Date()) -> Message? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty || !messages.isEmpty else { return nil }
        // With no new capture, an empty box has nothing new to ask.
        if text.isEmpty && pending.isEmpty { return nil }
        let m = Message(id: newId(), role: .user, createdAt: now, text: text.isEmpty ? Self.defaultQuestion : String(text.prefix(4000)),
                        attachments: pending.isEmpty ? nil : pending)
        pending = []
        messages.append(m)
        return m
    }

    mutating func appendAnswer(_ m: Message) { messages.append(m) }

    mutating func updateAnswer(_ id: String, _ change: (inout Message) -> Void) {
        if let i = messages.lastIndex(where: { $0.id == id }) { change(&messages[i]) }
    }

    /// The exchange as a normal chat, titled after the first question.
    func chat(now: Date = Date()) -> Chat? {
        let done = messages.filter { $0.role == .user || $0.status != .streaming }
        guard let first = done.first(where: { $0.role == .user }) else { return nil }
        let words = first.text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        return Chat(id: newId(), title: "Screen: \(words)", createdAt: first.createdAt, updatedAt: now, messages: done)
    }

    /// What the model reads before a screen question.
    static func systemPrompt(now: Date = Date()) -> String {
        // No date: with one, the model remarked that dates on screen were "outdated" (measured).
        """
        You are Tarn, an assistant that runs entirely on the user’s Mac.
        The user circled part of their Mac screen; each image is that part, cropped from a screenshot. \
        Answer exactly what they asked, using what is visible in the images and earlier in this conversation.
        Be brief: one to three sentences, or a few short numbered steps for "how do I" questions. \
        Refer to buttons, menus and labels by the names shown on screen.
        Don’t add anything they didn’t ask for: no extra percentages, calculations, tips or guesses about the app.
        If the image doesn’t show enough to answer, say what is missing. Never invent menu items, settings or \
        numbers that you can’t read in the image.
        """
    }
}
