// Social preview card (1200x630) for the website: white, mark + headline + app screenshot.
// Run: swift scripts/make_og.swift website/assets/app-light.jpg website/assets/og.png
import AppKit

let shot = NSImage(contentsOfFile: CommandLine.arguments[1])!
let W = 1200.0, H = 630.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Screenshot on the right, bleeding off the edge, with a soft shadow.
let sw = 760.0, sh = sw * shot.size.height / shot.size.width
let frame = NSRect(x: 520, y: (H - sh) / 2 - 40, width: sw, height: sh)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()

// Mark (32-unit grid), y flipped for AppKit.
let ink = NSColor(white: 0.086, alpha: 1)
func pt(_ x: Double, _ y: Double, s: Double, ox: Double, oy: Double) -> NSPoint { NSPoint(x: ox + x * s, y: oy - y * s) }
let s = 2.4, ox = 64.0, oy = H - 60
let ridge = NSBezierPath()
ridge.move(to: pt(3, 19, s: s, ox: ox, oy: oy))
for (x, y) in [(11.0, 8.5), (15.5, 14.0), (19.5, 9.5), (29.0, 19.0)] { ridge.line(to: pt(x, y, s: s, ox: ox, oy: oy)) }
ridge.lineWidth = 2.3 * s
ridge.lineCapStyle = .round
ridge.lineJoinStyle = .round
ink.setStroke()
ridge.stroke()
let lake = NSBezierPath()
lake.move(to: pt(6, 23.5, s: s, ox: ox, oy: oy))
lake.curve(to: pt(26, 23.5, s: s, ox: ox, oy: oy), controlPoint1: pt(10, 21.2, s: s, ox: ox, oy: oy), controlPoint2: pt(22, 21.2, s: s, ox: ox, oy: oy))
lake.curve(to: pt(6, 23.5, s: s, ox: ox, oy: oy), controlPoint1: pt(22, 27, s: s, ox: ox, oy: oy), controlPoint2: pt(10, 27, s: s, ox: ox, oy: oy))
ink.setFill()
lake.fill()
("Tarn" as NSString).draw(at: NSPoint(x: 150, y: H - 112), withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: ink])

let serif = NSFont(name: "Iowan Old Style", size: 58) ?? NSFont.systemFont(ofSize: 58)
let para = NSMutableParagraphStyle()
para.lineHeightMultiple = 0.95
("An AI that\nlives on\nyour Mac." as NSString).draw(in: NSRect(x: 64, y: 150, width: 440, height: 300),
    withAttributes: [.font: serif, .foregroundColor: ink, .paragraphStyle: para])
("Private. Free. No account." as NSString).draw(at: NSPoint(x: 66, y: 96),
    withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .regular), .foregroundColor: NSColor(white: 0.4, alpha: 1)])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("og written")
