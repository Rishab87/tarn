import Foundation

/// Water Tarn counts as saved for each answer written on the Mac instead of in a cloud data
/// center. Reasoning and sources: docs/WATER.md. The same explanation is shown in the app.
///
/// Google measured a median Gemini text prompt at 0.24 Wh and 0.26 mL of data-center cooling
/// water (Aug 2025). Generating that electricity also consumes water: at the US-average rate
/// implied by UC Riverside's study (14.7 mL per 4 Wh ≈ 3.7 mL/Wh), 0.24 Wh ≈ 0.88 mL.
/// 0.26 + 0.88 ≈ 1.1 mL per answer.
enum Water {
    static let mlPerAnswer = 1.1

    static let explanation =
        "Cloud AI uses water twice: to cool data centers, and to generate the electricity they run on. Google measured a typical chatbot answer at 0.26 mL of cooling water and 0.24 Wh of energy; producing that energy uses about 0.9 mL more at the US-average rate. Tarn counts 1.1 mL for every answer written on your Mac instead. Your Mac’s own electricity isn’t subtracted, and estimates vary a lot between data centers."

    static let sources: [(title: String, url: URL)] = [
        ("Google, “Measuring the environmental impact of delivering AI at Google Scale” (2025)", URL(string: "https://arxiv.org/abs/2508.15734")!),
        ("Li, Yang, Islam & Ren, “Making AI Less Thirsty” (UC Riverside)", URL(string: "https://arxiv.org/abs/2304.03271")!),
    ]

    /// Milestones that level the counter up, with a little sparkle: 1 L, 10 L, 100 L, 1,000 L.
    static let milestones: [Double] = [1_000, 10_000, 100_000, 1_000_000]

    /// The milestone passed when the total goes from `old` to `new` mL, if any.
    static func milestone(from old: Double, to new: Double) -> Double? {
        milestones.last { old < $0 && new >= $0 }
    }

    /// The counter's level (1 before the first milestone) and how far it is to the next one.
    static func level(_ ml: Double) -> (level: Int, next: Double?, progress: Double) {
        let passed = milestones.filter { ml >= $0 }.count
        guard passed < milestones.count else { return (passed + 1, nil, 1) }
        let previous = passed == 0 ? 0 : milestones[passed - 1], next = milestones[passed]
        return (passed + 1, next, max(0, min(1, (ml - previous) / (next - previous))))
    }

    static func format(_ ml: Double) -> String {
        // Below 999.5 mL; anything that would round to "1000 mL" reads as a litre.
        if ml < 999.5 { return "\(Int(ml.rounded())) mL" }
        let l = ml / 1000
        if l < 100 { return String(format: "%.1f L", l) }
        return "\(Int(l.rounded()).formatted()) L"
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let gb = Double(b) / 1e9
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int((Double(b) / 1e6).rounded())) MB"
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        if seconds < 60 { return "less than a minute" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "about \(m) minute\(m == 1 ? "" : "s")" }
        let h = m / 60, rest = m % 60
        return "about \(h) hour\(h == 1 ? "" : "s")" + (rest >= 10 ? " \(rest) min" : "")
    }

    static func tierLabel(_ tier: Tier, _ pick: ModelPick?) -> String {
        guard let pick else { return tier.name }
        return "\(tier.name) (\(pick.model.params))"
    }

    static func dayGroup(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "Previous 7 days" }
        if days < 30 { return "Previous 30 days" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    static func greeting(name: String?) -> String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        if let name, !name.isEmpty { return "\(part), \(name)" }
        return part
    }
}
