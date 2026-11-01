// Prints the CGWindowID of an on-screen window owned by a process id.
//   winid <pid> [main|settings]   main = widest window, settings = the narrower Settings window
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "main"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
func width(_ w: [String: Any]) -> Double { ((w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double) ?? 0 }
let pick = mode == "settings" ? mine.filter { width($0) < 760 }.first : mine.max { width($0) < width($1) }
if let w = pick { print(w[kCGWindowNumber as String]!) }
