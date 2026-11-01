import SwiftUI

/// Tarn's pixel-art touches: the website's mountains beside the greeting and in onboarding, and the
/// water counter's drop. Pixels land on whole screen pixels (1.5 or 3 points each on a Retina
/// display), so they stay crisp.

/// The time of day, on the website's hours: dawn 5–8, day 8–17, dusk 17–20, night after that.
/// `-TarnScene dusk` (dawn, day, dusk, night) pins one for screenshots and demo recordings.
enum PixelTime {
    static func phase(at date: Date) -> String {
        if let pinned = UserDefaults.standard.string(forKey: "TarnScene")?.lowercased(), ["dawn", "day", "dusk", "night"].contains(pinned) { return pinned }
        switch Calendar.current.component(.hour, from: date) {
        case 5..<8: return "dawn"
        case 8..<17: return "day"
        case 17..<20: return "dusk"
        default: return "night"
        }
    }

    /// An image name from the asset catalog: "Greet" + "Dusk", say.
    static func asset(_ prefix: String, at date: Date) -> String {
        let p = phase(at: date)
        return prefix + p.prefix(1).uppercased() + p.dropFirst()
    }
}

/// The website's mountains and lake in miniature beside the greeting, lit for the time of day, with
/// no sky behind them. The images are drawn by the website's own code (website/scene.js, via
/// scripts/make_scene_sprites.mjs), so the two always match.
struct PixelScene: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Image(PixelTime.asset("Greet", at: context.date))
                .resizable()
                .interpolation(.none)
                .frame(width: 78, height: 48)
        }
        .accessibilityHidden(true)
    }
}

/// Onboarding's lake: the same mountains, larger. While the AI downloads, the water rises in the
/// drained bed a pixel row at a time (`level` 0…1).
struct PixelLake: View {
    var level: Double

    /// The 140x77 images' lake starts at row 50 (scripts/make_scene_sprites.mjs).
    private static let height = 77.0, surface = 50.0

    var body: some View {
        TimelineView(.everyMinute) { context in
            let name = PixelTime.asset("Lake", at: context.date)
            GeometryReader { geo in
                let pixel = geo.size.height / Self.height
                let water = (Self.surface + (1 - min(1, max(0, level))) * (Self.height - Self.surface)).rounded(.down)
                ZStack(alignment: .top) {
                    Image(name + "Dry").resizable().interpolation(.none)
                    Image(name).resizable().interpolation(.none)
                        .mask(alignment: .top) { Rectangle().padding(.top, water * pixel) }
                }
            }
            .aspectRatio(140.0 / 77.0, contentMode: .fit)
        }
        .accessibilityElement()
        .accessibilityLabel("Lake \(Int(min(1, max(0, level)) * 100)) percent full")
    }
}

/// A pixel-art sprite: one character per pixel, mapped to colours; "." is transparent.
struct PixelSprite: View {
    let rows: [String]
    let colors: [Character: Color]
    var pixel: CGFloat = 1.5

    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let color = colors[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(rows.map(\.count).max() ?? 0) * pixel, height: CGFloat(rows.count) * pixel)
        .accessibilityHidden(true)
    }
}

/// The water counter's drop. `sparkle` (1…6) draws a frame of the little level-up animation that
/// plays when the water saved passes a milestone; 0 draws none.
struct PixelDrop: View {
    var sparkle = 0

    static let rows = [
        "...kk...",
        "..kook..",
        "..kook..",
        ".kwoook.",
        ".khoook.",
        "khoooosk",
        "khoooosk",
        "kooooosk",
        "koooossk",
        ".kssssk.",
        "..kkkk..",
    ]

    static let colors: [Character: Color] = [
        "k": Color(light: 0x1C5862, dark: 0x3B8994),
        "o": Color.water,
        "h": Color(light: 0x5AA6B2, dark: 0x9AD3DC),
        "w": Color(light: 0xE8F7F9, dark: 0xF4FDFF),
        "s": Color(light: 0x23656F, dark: 0x4F9EAB),
    ]

    var body: some View {
        PixelSprite(rows: Self.rows, colors: Self.colors)
            .overlay { if sparkle > 0 { Sparkle(frame: sparkle) } }
    }

    /// Three four-point stars around the drop that grow and shrink, Game Boy style. Drawn on a
    /// canvas larger than the drop (5 pixels of room at the sides, 2 above and below).
    private struct Sparkle: View {
        let frame: Int
        var body: some View {
            Canvas { ctx, _ in
                let p: CGFloat = 1.5
                let sizes = [0, 1, 2, 3, 2, 1, 0]
                for (i, spot) in [(9, 1), (-3, 4), (9, 8)].enumerated() {
                    let arm = sizes[max(0, min(sizes.count - 1, frame - i))]
                    guard arm > 0 else { continue }
                    var cells = [(0, 0)]
                    for d in 1..<arm { cells += [(d, 0), (-d, 0), (0, d), (0, -d)] }
                    for c in cells {
                        let rect = CGRect(x: CGFloat(spot.0 + 5 + c.0) * p, y: CGFloat(spot.1 + 2 + c.1) * p, width: p, height: p)
                        ctx.fill(Path(rect), with: .color(Color(light: 0xE0A21B, dark: 0xFFD66B)))
                    }
                }
            }
            .frame(width: 18 * 1.5, height: 15 * 1.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Progress to the next water milestone as a row of pixel blocks.
struct PixelBar: View {
    let progress: Double
    var blocks = 20

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<blocks, id: \.self) { i in
                Rectangle()
                    .fill(Double(i) < progress * Double(blocks) ? Color.water : Color.water.opacity(0.18))
                    .frame(width: 6, height: 7.5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(Int((progress * 100).rounded())) percent of the way to the next level")
    }
}
