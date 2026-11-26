// The document the screen demo opens in Preview: a one-page install guide for a made-up app,
// with its disk-space requirement in a box the demo circles. Also writes the DRY-RUN fixture
// (a stand-in "screen" used only by make_screen_demo.sh --dry-run, never in the video).
//   swiftc -O -o video/make_screen_props video/make_screen_props.swift && video/make_screen_props video/props
import AppKit
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "props", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Draws at 2x and saves as a 144-dpi PNG, so Preview opens it at `size` points.
func page(_ size: CGSize, _ name: String, _ draw: (CGRect) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)                       // draw top-down
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func text(_ s: String, _ font: NSFont, _ color: NSColor, at p: CGPoint, width: CGFloat = 600) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        .draw(with: CGRect(x: p.x, y: p.y, width: width, height: 400), options: [.usesLineFragmentOrigin])
}

let ink = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
let grey = NSColor(srgbRed: 0.42, green: 0.44, blue: 0.46, alpha: 1)
let accent = NSColor(srgbRed: 0.85, green: 0.40, blue: 0.16, alpha: 1)
let serif = { (s: CGFloat) in NSFont(name: "Iowan Old Style Bold", size: s) ?? .boldSystemFont(ofSize: s) }

/// The install guide. The requirements box is at (48, 196, 504, 196) in page points.
func guide(_ r: CGRect) {
    NSColor.white.setFill(); r.fill()
    accent.setFill(); CGRect(x: 0, y: 0, width: r.width, height: 10).fill()
    text("Kestrel Photo 4", serif(38), ink, at: CGPoint(x: 48, y: 52))
    text("Install guide for Mac  ·  Version 4.2", .systemFont(ofSize: 17), grey, at: CGPoint(x: 50, y: 108))
    text("Read this before you download.", .systemFont(ofSize: 16), ink, at: CGPoint(x: 50, y: 150))

    let box = CGRect(x: 48, y: 196, width: 504, height: 196)
    let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
    NSColor(srgbRed: 0.99, green: 0.96, blue: 0.93, alpha: 1).setFill(); path.fill()
    accent.withAlphaComponent(0.55).setStroke(); path.lineWidth = 2; path.stroke()
    text("BEFORE YOU INSTALL", .systemFont(ofSize: 13, weight: .bold), accent, at: CGPoint(x: 72, y: 218))
    let rows = [("Free disk space needed", "40 GB"), ("Download size", "9.6 GB"), ("macOS", "15 or later"), ("Mac", "Apple silicon")]
    for (i, (k, v)) in rows.enumerated() {
        let y = 252 + CGFloat(i) * 32
        text(k, .systemFont(ofSize: 18), ink, at: CGPoint(x: 72, y: y))
        text(v, .systemFont(ofSize: 18, weight: .semibold), ink, at: CGPoint(x: 360, y: y), width: 180)
    }

    text("How to install", .systemFont(ofSize: 20, weight: .semibold), ink, at: CGPoint(x: 50, y: 424))
    let steps = ["1.  Download Kestrel Photo 4 from your account page.",
                 "2.  Open the disk image and drag Kestrel Photo to Applications.",
                 "3.  Open it and sign in. Your library moves over automatically.",
                 "4.  Keep the installer until the first library scan finishes."]
    for (i, s) in steps.enumerated() { text(s, .systemFont(ofSize: 16), ink, at: CGPoint(x: 50, y: 462 + CGFloat(i) * 30), width: 500) }
    text("Questions? support@kestrel.example", .systemFont(ofSize: 14), grey, at: CGPoint(x: 50, y: 600))
}

try page(CGSize(width: 600, height: 640), "kestrel-install-guide.png", guide)

// DRY-RUN fixture: a 1470x956 stand-in screen with a storage card and the same guide. Labelled
// so it can never pass for the real thing.
try page(CGSize(width: 1470, height: 956), "DRY-RUN-fixture-screen.png") { r in
    NSColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1).setFill(); r.fill()
    text("DRY-RUN FIXTURE — NOT A REAL SCREEN", .systemFont(ofSize: 22, weight: .heavy), NSColor.systemRed, at: CGPoint(x: 40, y: 20), width: 900)
    let card = CGRect(x: 80, y: 140, width: 560, height: 220)
    NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
    text("Macintosh HD", .systemFont(ofSize: 26, weight: .semibold), ink, at: CGPoint(x: 110, y: 170))
    text("460 GB · APFS volume", .systemFont(ofSize: 16), grey, at: CGPoint(x: 110, y: 212))
    text("Used 13 GB        Free 218 GB", .systemFont(ofSize: 22), ink, at: CGPoint(x: 110, y: 280))
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: 760, yBy: 120); t.concat()
    guide(CGRect(x: 0, y: 0, width: 600, height: 640))
    NSGraphicsContext.restoreGraphicsState()
}
print("wrote \(out.path)/kestrel-install-guide.png and DRY-RUN-fixture-screen.png")
