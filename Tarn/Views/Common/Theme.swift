import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self = Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    /// The only colour in Tarn: water.
    static let water = Color(light: 0x2D7C89, dark: 0x6BB8C3)
    static let bubble = Color(light: 0xEDEEEB, dark: 0x2A2F31)
    static let codeBackground = Color(light: 0xF2F3F0, dark: 0x1F2425)
    static let sceneFar = Color(light: 0xDCE0DD, dark: 0x2D3536)
    static let sceneNear = Color(light: 0xC5CCC9, dark: 0x3B4647)
    static let warning = Color(light: 0x8A5A0B, dark: 0xE2B25A)
}

extension Font {
    /// Iowan Old Style ships with every Mac; New York is the fallback.
    static func prose(_ size: CGFloat = 16.5) -> Font { .custom("Iowan Old Style", size: size) }
    static func display(_ size: CGFloat) -> Font { .custom("Iowan Old Style", size: size) }
}

/// Tarn's mark: a mountain ridge above a still lake. Monochrome, like the app icon.
struct Mark: View {
    var size: CGFloat = 28
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 32
            var ridge = Path()
            ridge.move(to: CGPoint(x: 3 * s, y: 19 * s))
            ridge.addLine(to: CGPoint(x: 11 * s, y: 8.5 * s))
            ridge.addLine(to: CGPoint(x: 15.5 * s, y: 14 * s))
            ridge.addLine(to: CGPoint(x: 19.5 * s, y: 9.5 * s))
            ridge.addLine(to: CGPoint(x: 29 * s, y: 19 * s))
            ctx.stroke(ridge, with: .color(.primary), style: StrokeStyle(lineWidth: 2.3 * s, lineCap: .round, lineJoin: .round))
            var lake = Path()
            lake.move(to: CGPoint(x: 6 * s, y: 23.5 * s))
            lake.addCurve(to: CGPoint(x: 26 * s, y: 23.5 * s), control1: CGPoint(x: 10 * s, y: 21.6 * s), control2: CGPoint(x: 22 * s, y: 21.6 * s))
            lake.addCurve(to: CGPoint(x: 6 * s, y: 23.5 * s), control1: CGPoint(x: 22 * s, y: 26.6 * s), control2: CGPoint(x: 10 * s, y: 26.6 * s))
            ctx.fill(lake, with: .color(.primary))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A mountain cirque holding a small lake. While the AI downloads, the lake fills (0…1).
struct TarnScene: View {
    var level: Double

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 420, sy = size.height / 230
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            var far = Path()
            far.move(to: p(0, 128))
            for (x, y) in [(58, 82), (96, 104), (150, 46), (196, 92), (232, 70), (286, 112), (330, 64), (380, 100), (420, 84), (420, 160), (0, 160)] { far.addLine(to: p(Double(x), Double(y))) }
            far.closeSubpath()
            ctx.fill(far, with: .color(.sceneFar))

            var near = Path()
            near.move(to: p(0, 160))
            near.addLine(to: p(0, 120)); near.addLine(to: p(44, 104)); near.addLine(to: p(92, 138)); near.addLine(to: p(122, 150)); near.addLine(to: p(70, 150))
            near.addCurve(to: p(210, 206), control1: p(90, 182), control2: p(130, 204))
            near.addCurve(to: p(350, 150), control1: p(290, 204), control2: p(330, 182))
            near.addLine(to: p(300, 150)); near.addLine(to: p(338, 128)); near.addLine(to: p(378, 108)); near.addLine(to: p(420, 124))
            near.addLine(to: p(420, 230)); near.addLine(to: p(0, 230))
            near.closeSubpath()
            ctx.fill(near, with: .color(.sceneNear))

            var basin = Path()
            basin.move(to: p(70, 150))
            basin.addCurve(to: p(210, 206), control1: p(90, 182), control2: p(130, 204))
            basin.addCurve(to: p(350, 150), control1: p(290, 204), control2: p(330, 182))
            basin.closeSubpath()

            let l = min(1, max(0, level))
            let surface = 196 - l * 46
            ctx.drawLayer { layer in
                layer.clip(to: basin)
                layer.fill(Path(CGRect(x: 60 * sx, y: surface * sy, width: 300 * sx, height: 80 * sy)), with: .color(.water))
                if l > 0.04 {
                    for (x1, x2, dy) in [(150.0, 200.0, 9.0), (222.0, 262.0, 15.0), (176.0, 208.0, 22.0)] {
                        var r = Path()
                        r.move(to: p(x1, surface + dy))
                        r.addLine(to: p(x2, surface + dy))
                        layer.stroke(r, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.3 * sx, lineCap: .round))
                    }
                }
            }
            var rim = Path()
            rim.move(to: p(70, 150))
            rim.addCurve(to: p(210, 206), control1: p(90, 182), control2: p(130, 204))
            rim.addCurve(to: p(350, 150), control1: p(290, 204), control2: p(330, 182))
            ctx.stroke(rim, with: .color(.secondary.opacity(0.6)), lineWidth: 1.2 * sx)
        }
        .aspectRatio(420 / 230, contentMode: .fit)
        .animation(.easeInOut(duration: 0.6), value: level)
        .accessibilityLabel("Lake \(Int(level * 100)) percent full")
    }
}
