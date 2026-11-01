// Draws Tarn's app icon: a black mountain ridge above a still black lake on white.
// Full-bleed square artwork; macOS applies the rounded-square mask.
// Run: swift scripts/make_icon.swift
import AppKit

let out = URL(fileURLWithPath: "Tarn/Resources/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let size = CGFloat(px)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // The mark is designed on a 32-unit grid (see Mark in Theme.swift); flip to y-down.
    let s = size / 32 * 0.64
    let dx = size / 2 - 16 * s, dy = size / 2 - 17.6 * s
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * s, y: dy + y * s) }
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.setLineWidth(2.3 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: p(3, 19))
    ctx.addLine(to: p(11, 8.5))
    ctx.addLine(to: p(15.5, 14))
    ctx.addLine(to: p(19.5, 9.5))
    ctx.addLine(to: p(29, 19))
    ctx.strokePath()
    ctx.move(to: p(6, 23.5))
    ctx.addCurve(to: p(26, 23.5), control1: p(10, 21.6), control2: p(22, 21.6))
    ctx.addCurve(to: p(6, 23.5), control1: p(22, 26.6), control2: p(10, 26.6))
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! render(pt * sc).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(sc)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images")
