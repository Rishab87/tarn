// Stages the Mac for the screen demo without Apple Events or Accessibility (neither is needed):
//   stage hide <keep-bundle-id …>     hides every visible app except these; prints the hidden PIDs
//   stage unhide <pid …>               shows those apps again
//   stage quit <pid>                   asks an app this script started to quit (then waits)
//   stage window "<App Name>"          prints the app's front window: x y w h (points, top left)
//   stage running <bundle-id>          prints the PIDs of a running app, nothing if not running
//   stage still-hidden <pid …>         prints those of the PIDs whose apps are still hidden
//   stage locked                       exits 0 if the Mac's screen is locked
//   stage can-record                   exits 0 if this terminal has Screen Recording (never prompts)
// Build: swiftc -O -o video/stage video/stage.swift
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print("usage: stage hide|unhide|quit|window|running …"); exit(2) }
let rest = Array(args.dropFirst())

switch cmd {
case "hide":
    let keep = Set(rest)
    var asked: [pid_t] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden {
        if let id = app.bundleIdentifier, keep.contains(id) { continue }
        // hide() returns false even when the app does hide (measured on macOS 27), and cached
        // isHidden values don't update without a run loop. So report every app asked: the
        // restore unhides all of them (unhiding a visible app does nothing).
        _ = app.hide()
        asked.append(app.processIdentifier)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    print(asked.map(String.init).joined(separator: " "))
case "unhide":
    let pids = rest.compactMap { pid_t($0) }
    for attempt in 0..<3 {
        for p in pids { NSRunningApplication(processIdentifier: p)?.unhide() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Fresh lookups: cached objects don't see the change.
        if pids.allSatisfy({ NSRunningApplication(processIdentifier: $0)?.isHidden != true }) || attempt == 2 { break }
    }
case "quit":
    guard let p = rest.first.flatMap({ pid_t($0) }), let app = NSRunningApplication(processIdentifier: p) else { exit(0) }
    app.terminate()
    for _ in 0..<50 where !app.isTerminated { Thread.sleep(forTimeInterval: 0.1) }
    if !app.isTerminated { app.forceTerminate() }
case "window":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerName as String] as? String) == rest.first && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let b = w[kCGWindowBounds as String] as? [String: Double], let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 200 {
            print(Int(r.minX), Int(r.minY), Int(r.width), Int(r.height), w[kCGWindowNumber as String] as? Int ?? 0)
            exit(0)
        }
    }
    exit(1)
case "running":
    let pids = NSRunningApplication.runningApplications(withBundleIdentifier: rest.first ?? "").map { String($0.processIdentifier) }
    print(pids.joined(separator: " "))
case "still-hidden":
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    print(rest.compactMap { pid_t($0) }.filter { NSRunningApplication(processIdentifier: $0)?.isHidden == true }.map(String.init).joined(separator: " "))
case "locked":
    let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
    exit((d["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1 ? 0 : 1)
case "can-record":
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
default:
    print("unknown command \(cmd)"); exit(2)
}
