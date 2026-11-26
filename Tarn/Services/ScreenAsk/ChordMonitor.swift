import AppKit
import CoreGraphics

/// Watches for the ⌥⌘ / ⇧⌥⌘ hold in every app without any macOS permission.
///
/// It polls instead of listening to events: the modifier keys held right now
/// (`NSEvent.modifierFlags`), and how long ago the newest key press, mouse press and modifier
/// change happened (`CGEventSource.secondsSinceLastEventType`). macOS gives both to any app
/// without asking for a permission, and neither says which key was pressed.
/// ChordPoller turns those samples into a held chord; ordinary shortcuts such as ⌥⌘Esc or
/// ⌥⌘-click cancel it because a key or button went down after ⌥⌘ did.
///
/// Cost: a 10 Hz timer while nothing is held (with tolerance, so macOS can coalesce it), 60 Hz
/// only while ⌥ or ⌘ is down. Each poll is a few cheap reads.
@MainActor
final class ChordMonitor {
    var onChord: ((CaptureMode) -> Void)?
    private(set) var running = false

    static let idleInterval: TimeInterval = 0.1
    static let fastInterval: TimeInterval = 1.0 / 60

    private var poller = ChordPoller()
    private var timer: Timer?
    private var fast = false
    /// Keeps App Nap from slowing the timer while Tarn sits in the background with no window.
    private var activity: NSObjectProtocol?
    /// Debug hooks: a scripted "hand" instead of the real keyboard.
    private var fed: ChordDetector.Mods?

    func start() {
        guard !running else { return }
        running = true
        poller = ChordPoller()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Listening for ⌥⌘ to ask about the screen")
        schedule(fast: false)
    }

    func stop() {
        running = false
        fed = nil
        timer?.invalidate()
        timer = nil
        poller = ChordPoller()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Debug hooks: holds these modifiers as if pressed (nothing else is pressed meanwhile).
    func feed(_ mods: ChordDetector.Mods) {
        fed = mods
        if timer == nil { schedule(fast: true) }
        poll()
    }

    private func schedule(fast: Bool) {
        timer?.invalidate()
        self.fast = fast
        let t = Timer(timeInterval: fast ? Self.fastInterval : Self.idleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = fast ? 0.004 : 0.05
        // .common so it keeps running while a menu is open or a window is being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        if let mode = poller.update(sample()) { onChord?(mode) }
        if !running, fed?.isEmpty ?? true, !poller.wantsFastPolling {
            // A scripted hold has ended and nothing listens for real: stop.
            timer?.invalidate()
            timer = nil
            fed = nil
            return
        }
        if poller.wantsFastPolling != fast { schedule(fast: poller.wantsFastPolling) }
    }

    private func sample() -> ChordPoller.Sample {
        let now = ProcessInfo.processInfo.systemUptime
        if let fed {
            return ChordPoller.Sample(now: now, mods: fed, keyAt: -.infinity, mouseAt: -.infinity, flagsAt: now)
        }
        let src = CGEventSourceStateID.combinedSessionState
        let key = CGEventSource.secondsSinceLastEventType(src, eventType: .keyDown)
        let mouse = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(src, eventType: $0) }.min() ?? .infinity
        let flags = CGEventSource.secondsSinceLastEventType(src, eventType: .flagsChanged)
        return ChordPoller.Sample(now: now, mods: Self.mods(NSEvent.modifierFlags), keyAt: now - key, mouseAt: now - mouse, flagsAt: now - flags)
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> ChordDetector.Mods {
        var m: ChordDetector.Mods = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.command) { m.insert(.command) }
        return m
    }
}
