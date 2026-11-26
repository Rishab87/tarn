import CoreGraphics
import Foundation
import Testing
@testable import Tarn

@Suite("Screen ask: ⌥⌘ chord")
struct ChordDetectorTests {
    typealias M = ChordDetector.Mods

    @Test func holdingOptionCommandFiresOnceAfterTheHold() {
        var d = ChordDetector()
        d.flagsChanged([.command], at: 0)
        d.flagsChanged([.command, .option], at: 0.05)
        #expect(d.tick(at: 0.2) == nil)
        #expect(d.tick(at: 0.40) == .fresh)
        #expect(d.tick(at: 1.0) == nil) // still held: no repeat
        d.flagsChanged([], at: 1.2)
        d.flagsChanged([.option, .command], at: 2)
        #expect(d.tick(at: 2.4) == .fresh)
    }

    @Test func anOrdinaryShortcutNeverFires() {
        // ⌥⌘Esc (Force Quit): the key arrives before the hold time.
        var d = ChordDetector()
        d.flagsChanged([.option, .command], at: 0)
        d.keyDown(at: 0.15)
        #expect(d.tick(at: 0.35) == nil)
        #expect(d.tick(at: 5) == nil)
        // Still blocked while either modifier stays down, even after the key goes up.
        d.flagsChanged([.command], at: 5.1)
        d.flagsChanged([.option, .command], at: 5.2)
        #expect(d.tick(at: 6) == nil)
        d.flagsChanged([], at: 6.1)
        d.flagsChanged([.option, .command], at: 7)
        #expect(d.tick(at: 7.4) == .fresh)
    }

    @Test func clickingWhileHoldingIsNotTheChord() {
        var d = ChordDetector()
        d.flagsChanged([.option, .command], at: 0)
        d.mouseDown(at: 0.1) // ⌥⌘-drag in Finder, ⌥⌘-click in Dock
        #expect(d.tick(at: 1) == nil)
    }

    @Test func releasingEarlyDoesNothing() {
        var d = ChordDetector()
        d.flagsChanged([.option, .command], at: 0)
        d.flagsChanged([.option], at: 0.2)
        #expect(d.tick(at: 0.5) == nil)
        #expect(d.state == .idle)
    }

    @Test func shiftMakesItAnAppend() {
        var d = ChordDetector()
        d.flagsChanged([.shift], at: 0)
        d.flagsChanged([.shift, .command], at: 0.03) // not a chord yet
        d.flagsChanged([.shift, .command, .option], at: 0.06)
        #expect(d.tick(at: 0.42) == .append)
    }

    @Test func addingShiftLateRestartsTheTimerAndDecides() {
        var d = ChordDetector()
        d.flagsChanged([.option, .command], at: 0)
        d.flagsChanged([.option, .command, .shift], at: 0.2)
        #expect(d.tick(at: 0.4) == nil) // the ⌥⌘ timer was replaced
        #expect(d.tick(at: 0.56) == .append)
    }

    @Test func controlSpoilsIt() {
        var d = ChordDetector()
        d.flagsChanged([.option, .command], at: 0)
        d.flagsChanged([.option, .command, .control], at: 0.1)
        #expect(d.tick(at: 1) == nil)
        d.flagsChanged([.option, .command], at: 1.1) // ⌃ released, ⌥⌘ still down: stays blocked
        #expect(d.tick(at: 2) == nil)
    }

    @Test func otherModifierCombosAreIgnored() {
        var d = ChordDetector()
        for m: M in [[.command], [.option], [.shift, .command], [.control, .option], [.control, .command, .option]] {
            d.flagsChanged(m, at: 0)
            #expect(d.tick(at: 1) == nil)
            d.flagsChanged([], at: 1.1)
        }
    }

    @Test func deadlineIsForTheArmedChord() {
        var d = ChordDetector(hold: 0.5)
        #expect(d.deadline == nil)
        d.flagsChanged([.option, .command], at: 10)
        #expect(d.deadline == 10.5)
    }
}

@Suite("Screen ask: polling the keyboard without a permission")
struct ChordPollerTests {
    typealias Sample = ChordPoller.Sample
    let never = -1.0e9 // "no such event yet"

    /// Polls like ChordMonitor: 10 Hz while nothing is held, 60 Hz while ⌥ or ⌘ is down.
    /// `mods(t)` is what's held at time t; events are the times of key, mouse and modifier changes.
    func run(until end: Double, start: Double = 0.013, mods: (Double) -> ChordDetector.Mods,
             keys: [Double] = [], clicks: [Double] = [], flagChanges: [Double],
             flagsTimerStuckAtNow: Bool = false) -> (fired: CaptureMode?, at: Double?) {
        var p = ChordPoller()
        var t = start
        while t <= end {
            let last = { (events: [Double]) in events.filter { $0 <= t }.max() ?? self.never }
            let flagsAt = flagsTimerStuckAtNow ? t : last(flagChanges)
            if let mode = p.update(Sample(now: t, mods: mods(t), keyAt: last(keys), mouseAt: last(clicks), flagsAt: flagsAt)) {
                return (mode, t)
            }
            t += p.wantsFastPolling ? 1.0 / 60 : 0.1
        }
        return (nil, nil)
    }

    @Test func holdingOptionCommandFiresAfterTheHoldFromTheRealPress() {
        // ⌘ at 0.30 s, ⌥ at 0.34 s. The idle poll at 0.313 s sees ⌘ and switches to 60 Hz; the hold
        // is timed from the real modifier change (0.34 s), so it fires within one fast poll of 0.69 s.
        let r = run(until: 3, mods: { $0 >= 0.34 ? [.option, .command] : ($0 >= 0.30 ? [.command] : []) }, flagChanges: [0.30, 0.34])
        #expect(r.fired == .fresh)
        #expect(r.at! >= 0.69 && r.at! < 0.69 + 1.0 / 60 + 0.001)
    }

    @Test func optionCommandEscIsAShortcut() {
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 && t < 0.9 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, keys: [0.52], flagChanges: [0.34, 0.9]).fired == nil)
    }

    @Test func aKeyBetweenTwoIdlePollsStillCancels() {
        // ⌥⌘ at 0.32 s and Esc at 0.36 s both land before the poll at 0.413 s notices anything.
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.32 && t < 1.2 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, keys: [0.36], flagChanges: [0.32, 1.2]).fired == nil)
    }

    @Test func typingJustBeforeTheChordDoesNotCancelIt() {
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, keys: [0.10, 0.25], flagChanges: [0.34]).fired == .fresh)
    }

    @Test func optionCommandClickIsNotTheChord() {
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, clicks: [0.5], flagChanges: [0.34]).fired == nil)
    }

    @Test func shiftOptionCommandAppends() {
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 ? [.shift, .option, .command] : [] }
        #expect(run(until: 3, mods: held, flagChanges: [0.34]).fired == .append)
    }

    @Test func letGoBeforeTheHoldDoesNothing() {
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 && t < 0.55 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, flagChanges: [0.34, 0.55]).fired == nil)
    }

    @Test func unreadableModifierTimerFallsBackToThePreviousPoll() {
        // If macOS ever stops reporting when modifiers changed, the press is assumed to have
        // happened right after the previous poll: a key since then still cancels...
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, keys: [0.35], flagChanges: []).fired == nil)
        // ...and a clean hold still fires, timed from that poll (0.313 s), so a little early.
        let r = run(until: 3, mods: held, flagChanges: [])
        #expect(r.fired == .fresh)
        #expect(r.at! >= 0.313 + 0.35 - 0.001 && r.at! < 0.75)
    }

    @Test func aModifierTimerStuckAtNowStillCancelsAFastShortcut() {
        // ⌥⌘ at 0.34 s and Esc at 0.36 s, but the modifier timer claims "just now" at every poll.
        let held = { (t: Double) -> ChordDetector.Mods in t >= 0.34 && t < 1.2 ? [.option, .command] : [] }
        #expect(run(until: 3, mods: held, keys: [0.36], flagChanges: [], flagsTimerStuckAtNow: true).fired == nil)
        // A clean hold still fires; it's timed from the poll that saw it, so it feels ~0.1 s slower.
        let clean = run(until: 3, mods: { $0 >= 0.34 ? [.option, .command] : [] }, flagChanges: [], flagsTimerStuckAtNow: true)
        #expect(clean.fired == .fresh)
        #expect(clean.at! >= 0.413 + 0.35 - 0.001 && clean.at! < 0.413 + 0.35 + 1.0 / 60 + 0.001)
    }

    @Test func pollsFastOnlyWhileOptionOrCommandIsDown() {
        var p = ChordPoller()
        _ = p.update(Sample(now: 1, mods: [.shift], keyAt: never, mouseAt: never, flagsAt: 0.9))
        #expect(!p.wantsFastPolling)
        _ = p.update(Sample(now: 1.1, mods: [.command], keyAt: never, mouseAt: never, flagsAt: 1.05))
        #expect(p.wantsFastPolling)
        _ = p.update(Sample(now: 1.2, mods: [], keyAt: never, mouseAt: never, flagsAt: 1.15))
        #expect(!p.wantsFastPolling)
    }

    @Test func firesOncePerHold() {
        var p = ChordPoller()
        var fired = 0
        var t = 0.0
        while t < 3 {
            if p.update(Sample(now: t, mods: [.option, .command], keyAt: never, mouseAt: never, flagsAt: 0)) != nil { fired += 1 }
            t += 1.0 / 60
        }
        #expect(fired == 1)
    }
}

@Suite("Screen ask: overlay failsafe")
struct OverlayFailsafeTests {
    @Test func dismissesAfterThirtySecondsWithoutASelection() {
        let f = OverlayFailsafe(shownAt: 100)
        #expect(!f.shouldDismiss(at: 129.9, drawing: false))
        #expect(f.shouldDismiss(at: 130, drawing: false))
    }

    @Test func aStrokeInProgressGetsMoreTimeButNotForever() {
        let f = OverlayFailsafe(shownAt: 100)
        #expect(!f.shouldDismiss(at: 131, drawing: true))
        #expect(!f.shouldDismiss(at: 144.9, drawing: true))
        #expect(f.shouldDismiss(at: 145, drawing: true)) // a lost mouse-up can't hold the screen
    }
}

@Suite("Screen ask: selection to crop")
struct ScreenGeometryTests {
    @Test func loopBecomesItsPaddedBoundingBox() {
        let loop = [CGPoint(x: 100, y: 120), CGPoint(x: 180, y: 100), CGPoint(x: 220, y: 160), CGPoint(x: 140, y: 210), CGPoint(x: 104, y: 150)]
        let s = ScreenGeometry.selection(from: loop, in: CGSize(width: 1512, height: 982), padding: 10)
        #expect(s == CGRect(x: 90, y: 90, width: 140, height: 130))
    }

    @Test func diagonalDragIsARectangle() {
        let drag = [CGPoint(x: 300, y: 200), CGPoint(x: 350, y: 260), CGPoint(x: 500, y: 400)]
        #expect(ScreenGeometry.selection(from: drag, in: CGSize(width: 1000, height: 800), padding: 0) == CGRect(x: 300, y: 200, width: 200, height: 200))
    }

    @Test func strayClickIsNoSelection() {
        #expect(ScreenGeometry.selection(from: [CGPoint(x: 5, y: 5), CGPoint(x: 8, y: 9)], in: CGSize(width: 100, height: 100)) == nil)
        #expect(ScreenGeometry.selection(from: [], in: CGSize(width: 100, height: 100)) == nil)
    }

    @Test func selectionStaysOnTheDisplay() {
        let s = ScreenGeometry.selection(from: [CGPoint(x: -20, y: 5), CGPoint(x: 60, y: 50)], in: CGSize(width: 50, height: 40), padding: 10)
        #expect(s == CGRect(x: 0, y: 0, width: 50, height: 40))
    }

    @Test func retinaCropIsTwicePoints() {
        let r = ScreenGeometry.cropRect(selection: CGRect(x: 90, y: 90, width: 140, height: 130),
                                        viewSize: CGSize(width: 1512, height: 982), imageSize: CGSize(width: 3024, height: 1964))
        #expect(r == CGRect(x: 180, y: 180, width: 280, height: 260))
    }

    @Test func scaledDisplayModeSnapsOutwardToWholePixels() {
        // 1.5 px per point (a "More Space" style mode captured at its native pixels).
        let r = ScreenGeometry.cropRect(selection: CGRect(x: 10.3, y: 20.5, width: 33.3, height: 10),
                                        viewSize: CGSize(width: 1000, height: 600), imageSize: CGSize(width: 1500, height: 900))!
        #expect(r == CGRect(x: 15, y: 30, width: 51, height: 16))
        // Covers every pixel the selection touches.
        #expect(r.minX <= 10.3 * 1.5 && r.maxX >= (10.3 + 33.3) * 1.5)
    }

    @Test func cropClipsToTheImage() {
        let r = ScreenGeometry.cropRect(selection: CGRect(x: 900, y: 500, width: 200, height: 200),
                                        viewSize: CGSize(width: 1000, height: 600), imageSize: CGSize(width: 2000, height: 1200))
        #expect(r == CGRect(x: 1800, y: 1000, width: 200, height: 200))
        #expect(ScreenGeometry.cropRect(selection: .zero, viewSize: .zero, imageSize: CGSize(width: 10, height: 10)) == nil)
    }

    @Test func secondaryDisplayToGlobal() {
        // A display to the left of and above the main one (AppKit: bottom-left origin).
        let frame = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        let g = ScreenGeometry.toGlobal(CGRect(x: 100, y: 50, width: 200, height: 100), screenFrame: frame)
        #expect(g == CGRect(x: -1820, y: 300 + 1080 - 150, width: 200, height: 100))
    }

    @Test func panelGoesRightThenLeftThenBelow() {
        let v = CGRect(x: 0, y: 0, width: 1500, height: 950)
        let p = CGSize(width: 380, height: 300)
        let right = ScreenGeometry.panelOrigin(selection: CGRect(x: 100, y: 400, width: 200, height: 150), panel: p, visible: v)
        #expect(right == CGPoint(x: 314, y: 250)) // top-aligned with the selection
        let left = ScreenGeometry.panelOrigin(selection: CGRect(x: 1200, y: 400, width: 200, height: 150), panel: p, visible: v)
        #expect(left == CGPoint(x: 1200 - 14 - 380, y: 250))
        let below = ScreenGeometry.panelOrigin(selection: CGRect(x: 300, y: 500, width: 900, height: 300), panel: p, visible: v)
        #expect(below == CGPoint(x: 300, y: 500 - 14 - 300))
    }

    @Test func bigSelectionGetsTheSpotCoveringLeast() {
        // Measured case: a wide selection on a 1470×956 display, Dock at the bottom. No spot is
        // fully clear; just below the selection covers none of it once clamped above the Dock.
        let v = CGRect(x: 0, y: 90, width: 1470, height: 819)
        let o = ScreenGeometry.panelOrigin(selection: CGRect(x: 370, y: 566, width: 780, height: 310), panel: CGSize(width: 400, height: 470), visible: v)
        #expect(o == CGPoint(x: 370, y: 90))
    }

    @Test func panelNeverLeavesTheVisibleArea() {
        let v = CGRect(x: -1920, y: 300, width: 1920, height: 1050)
        let p = CGSize(width: 380, height: 300)
        for s in [CGRect(x: -1900, y: 1300, width: 60, height: 40), CGRect(x: -1910, y: 305, width: 1900, height: 1040), CGRect(x: -40, y: 310, width: 30, height: 30)] {
            let o = ScreenGeometry.panelOrigin(selection: s, panel: p, visible: v)
            let r = CGRect(origin: o, size: p)
            #expect(v.contains(r), "panel \(r) outside \(v) for selection \(s)")
        }
    }
}

@Suite("Screen ask: conversation context")
struct ScreenAskSessionTests {
    func capture(_ n: Int) -> Tarn.Attachment {
        Tarn.Attachment(id: "cap\(n)", name: "Screen capture \(n)", kind: .image, size: 1000, text: "", file: "cap\(n).jpg")
    }

    @Test func emptyReturnAsksWhatIsThis() {
        var s = ScreenAskSession()
        s.add(capture(1), mode: .fresh)
        let m = s.submit("   ")
        #expect(m?.text == "What is this?")
        #expect(m?.attachments == [capture(1)])
        #expect(s.pending.isEmpty)
    }

    @Test func nothingToAskAboutWithoutACapture() {
        var s = ScreenAskSession()
        #expect(s.submit("hello") == nil)
        s.add(capture(1), mode: .fresh)
        _ = s.submit("what app is this")
        // A follow-up with an empty box and no new capture is ignored.
        #expect(s.submit("") == nil)
    }

    @Test func freshCaptureStartsANewContext() {
        var s = ScreenAskSession()
        s.add(capture(1), mode: .fresh)
        _ = s.submit("what is this")
        s.appendAnswer(Message(id: "a1", role: .assistant, createdAt: Date(), blocks: [.text("A chart.")], status: .done))
        s.add(capture(2), mode: .fresh)
        #expect(s.messages.isEmpty)
        #expect(s.captures == [capture(2)])
    }

    @Test func appendedCaptureJoinsTheConversation() {
        var s = ScreenAskSession()
        s.add(capture(1), mode: .fresh)
        _ = s.submit("what is this")
        s.appendAnswer(Message(id: "a1", role: .assistant, createdAt: Date(), blocks: [.text("A chart.")], status: .done))
        s.add(capture(2), mode: .append)
        #expect(s.messages.count == 2)
        let m = s.submit("and how does this compare?")
        #expect(m?.attachments == [capture(2)])
        #expect(s.captures == [capture(1), capture(2)])
        // The model sees the conversation in order, with both images still as pixels.
        let h = Prompt.history(s.messages, imageDataURL: { "data:\($0.id)" })
        #expect(h.count == 3)
        #expect((h[0]["content"] as? [[String: Any]])?.count == 2)
        #expect((h[2]["content"] as? [[String: Any]])?.count == 2)
    }

    @Test func appendWithNothingOpenActsFresh() {
        var s = ScreenAskSession()
        s.add(capture(1), mode: .append)
        #expect(s.captures == [capture(1)])
        #expect(s.submit("")?.attachments == [capture(1)])
    }

    @Test func followUpWithoutCaptureStillSeesTheImage() {
        var s = ScreenAskSession()
        s.add(capture(1), mode: .fresh)
        _ = s.submit("what is this")
        s.appendAnswer(Message(id: "a1", role: .assistant, createdAt: Date(), blocks: [.text("Xcode.")], status: .done))
        let m = s.submit("how do I run the tests here?")
        #expect(m?.attachments == nil)
        #expect(Prompt.needsVision(s.messages))
    }

    @Test func pendingCapturesAreCapped() {
        var s = ScreenAskSession()
        for i in 1...6 { s.add(capture(i), mode: .append) }
        #expect(s.pending.map(\.id) == ["cap3", "cap4", "cap5", "cap6"])
    }

    @Test func continueInChatKeepsTheExchange() {
        var s = ScreenAskSession()
        s.add(capture(1), mode: .fresh)
        _ = s.submit("")
        s.appendAnswer(Message(id: "a1", role: .assistant, createdAt: Date(), blocks: [.text("It is the Wi-Fi menu.")], status: .done))
        s.appendAnswer(Message(id: "a2", role: .assistant, createdAt: Date(), status: .streaming))
        let chat = s.chat()
        #expect(chat?.title == "Screen: What is this?")
        #expect(chat?.messages.map(\.id).contains("a2") == false) // an unfinished answer stays behind
        #expect(chat?.messages.first?.attachments == [capture(1)])
        #expect(ScreenAskSession().chat() == nil)
    }
}

#if DEBUG
@Suite("Screen ask: Debug hooks")
struct ScreenAskDebugHookTests {
    /// Regression: a Debug build launched with no hook arguments switched the overlay to
    /// click-through and suppressed permission prompts, so a person could not circle or press Esc.
    @Test func plainLaunchIsNotAutomation() {
        let name = "tarn.tests.screenask.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        #expect(!ScreenAskController.automationRequested(d))
        d.set("YES", forKey: "TarnScreenAskFocus") // the focus flag alone starts no hook
        #expect(!ScreenAskController.automationRequested(d))
        for key in ScreenAskController.automationKeys {
            d.set("x", forKey: key)
            #expect(ScreenAskController.automationRequested(d))
            d.removeObject(forKey: key)
        }
    }
}
#endif
