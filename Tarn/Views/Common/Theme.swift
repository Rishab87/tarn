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
    static let warning = Color(light: 0x8A5A0B, dark: 0xE2B25A)
    /// Primary buttons: near-black in light mode, near-white in dark mode, with readable labels.
    static let ink = Color(light: 0x161616, dark: 0xF2F2EF)
    static let onInk = Color(light: 0xFFFFFF, dark: 0x111111)
}

/// The one prominent action on a screen: an ink capsule that stays readable in light and dark
/// mode and in inactive windows (system prominent buttons turn grey there).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size

    func makeBody(configuration: Configuration) -> some View {
        let large = size == .large || size == .extraLarge
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold))
            .foregroundStyle(Color.onInk)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 11 : 6)
            .background(Color.ink.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.3), in: .capsule)
            .contentShape(.capsule)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Round send/stop button for the composer.
struct SendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(enabled ? Color.onInk : Color.secondary)
            .frame(width: 32, height: 32)
            .background(enabled ? Color.ink.opacity(configuration.isPressed ? 0.78 : 1) : Color.secondary.opacity(0.18), in: .circle)
            .contentShape(.circle)
    }
}

extension View {
    func primaryButton() -> some View { buttonStyle(PrimaryButtonStyle()) }
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

