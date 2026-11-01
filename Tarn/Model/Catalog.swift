import Foundation

/// The models Tarn knows about ship inside the app (Resources/catalog.json). New models arrive
/// with app updates, never by themselves. See docs/MODELS.md for how they were chosen.
enum Catalog {
    static let all: [CatalogModel] = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let models = try? JSONDecoder().decode([CatalogModel].self, from: data) else { return [] }
        return models
    }()

    static func model(_ id: String?) -> CatalogModel? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

enum ModelFit {
    static let GiB: Double = 1_073_741_824

    /// Context sizes tried, largest first. Agentic tasks need room for tool results.
    static let contextSteps = [32768, 16384, 8192]

    /// Below this generation speed answers feel sluggish, so a model won't be recommended.
    static let minTokensPerSec = 12.0

    /// Share of theoretical memory bandwidth llama.cpp reaches while generating on Apple
    /// Silicon. Measured on an M5 (153 GB/s): 2B ≈0.58, 4B 0.63, 9B 0.78. 0.62 sits at the low end
    /// so estimates for 4B-and-up models err on the slow side; see docs/MODELS.md.
    static let bandwidthEfficiency = 0.62

    /// Cap on llama-server's in-RAM cache of earlier prompts (it defaults to 8 GiB).
    static let promptCacheMiB = 256

    /// How much memory the AI may use on this Mac.
    ///
    /// The rest is kept free for macOS, a browser with a dozen tabs and everyday apps, so the
    /// Mac doesn't slow down while Tarn is loaded: half of RAM, at least 4.5 GiB and at most
    /// 12 GiB. The result also stays under what macOS lets the GPU keep resident.
    static func budget(ramBytes: Int64, gpuWorkingSetBytes: Int64?) -> Int64 {
        let ram = Double(ramBytes)
        let reserve = min(max(0.5 * ram, 4.5 * GiB), 12 * GiB)
        let gpu = Double(gpuWorkingSetBytes ?? Int64(ram * (ram > 36 * GiB ? 0.75 : 2.0 / 3.0))) - 0.5 * GiB
        return Int64(max(0, min(ram - reserve, gpu)))
    }

    static func footprint(_ m: CatalogModel, context: Int) -> Int64 {
        m.file.size + m.kvBytesPerToken * Int64(context) + m.overheadBytes + Int64(promptCacheMiB) * 1_048_576
    }

    /// Generation is memory-bound: every token reads the active weights once.
    static func tokensPerSec(_ m: CatalogModel, bandwidthGBs: Double?) -> Double? {
        guard let bw = bandwidthGBs else { return nil }
        let bytesPerToken = Double(m.file.size) * (m.activeParamsB / m.totalParamsB)
        return bw * 1e9 * bandwidthEfficiency / bytesPerToken
    }

    /// Largest context step that fits the budget, or nil if the model doesn't fit at all.
    static func fit(_ m: CatalogModel, budget: Int64, bandwidthGBs: Double?) -> ModelPick? {
        for ctx in contextSteps where ctx <= m.maxContext {
            let bytes = footprint(m, context: ctx)
            if bytes <= budget {
                return ModelPick(model: m, contextTokens: ctx, footprintBytes: bytes, estTokensPerSec: tokensPerSec(m, bandwidthGBs: bandwidthGBs))
            }
        }
        return nil
    }

    /// Recommended: the highest-quality model that fits the budget and still writes at a
    /// comfortable reading speed. Lighter: the best model using at most 60% of the recommended
    /// one's memory, so switching frees a meaningful amount for heavy work.
    static func picks(ramBytes: Int64, gpuWorkingSetBytes: Int64?, bandwidthGBs: Double?, catalog: [CatalogModel] = Catalog.all) -> Picks {
        let budget = budget(ramBytes: ramBytes, gpuWorkingSetBytes: gpuWorkingSetBytes)
        let fits = catalog.compactMap { fit($0, budget: budget, bandwidthGBs: bandwidthGBs) }
        let fast = fits.filter { ($0.estTokensPerSec ?? .infinity) >= minTokensPerSec }
        let better: (ModelPick, ModelPick) -> Bool = {
            $0.model.quality != $1.model.quality ? $0.model.quality > $1.model.quality : $0.footprintBytes < $1.footprintBytes
        }
        // Nothing fast enough (very old or unknown chip): fall back to the smallest model that fits.
        let pool = fast.isEmpty ? Array(fits.sorted { $0.footprintBytes < $1.footprintBytes }.prefix(1)) : fast
        guard let rec = pool.sorted(by: better).first else { return Picks(recommended: nil, lighter: nil, budgetBytes: budget) }
        var lighter = fits
            .filter { $0.model.id != rec.model.id && Double($0.footprintBytes) <= 0.6 * Double(rec.footprintBytes) }
            .sorted(by: better).first
        if lighter == nil {
            lighter = fits
                .filter { $0.model.id != rec.model.id && $0.footprintBytes < rec.footprintBytes }
                .sorted { $0.footprintBytes < $1.footprintBytes }.first
        }
        return Picks(recommended: rec, lighter: lighter, budgetBytes: budget)
    }
}

// MARK: - Apple Silicon

/// Unified memory bandwidth (GB/s) from Apple's published specifications (support.apple.com
/// tech specs; M1 from AnandTech). Sources and caveats: docs/MODELS.md.
enum Chips {
    struct Entry {
        var base: Double?
        var pro: Double?
        /// Max chips come in two bandwidth bins, told apart by GPU core count.
        var max: (lowGpuCores: Int, low: Double, high: Double)?
        var maxSingle: Double?
        var ultra: Double?
    }

    static let table: [String: Entry] = [
        "M1": Entry(base: 68, pro: 200, maxSingle: 400, ultra: 800),
        "M2": Entry(base: 100, pro: 200, maxSingle: 400, ultra: 800),
        "M3": Entry(base: 100, pro: 150, max: (30, 300, 400), ultra: 819),
        "M4": Entry(base: 120, pro: 273, max: (32, 410, 546)),
        "M5": Entry(base: 153, pro: 307, max: (32, 460, 614), ultra: 1200),
        "M6": Entry(base: 153),
        // MacBook Neo (2026): iPhone-class chip, 8 GB.
        "A18": Entry(pro: 60),
    ]

    static func parse(_ chip: String) -> (family: String?, variant: ChipVariant?) {
        guard let m = chip.firstMatch(of: /\b([MA])(\d+)\s*(Pro|Max|Ultra)?\b/) else { return (nil, nil) }
        let variant: ChipVariant = switch m.3.map(String.init) {
        case "Pro": .pro
        case "Max": .max
        case "Ultra": .ultra
        default: .base
        }
        return ("\(m.1)\(m.2)", variant)
    }

    static func bandwidth(family: String?, variant: ChipVariant?, gpuCores: Int?) -> Double? {
        guard let family, let variant else { return nil }
        if let v = lookup(family, variant, gpuCores) { return v }
        // An M chip newer than this table: assume at least the newest known chip of that tier.
        guard family.hasPrefix("M"), let n = Int(family.dropFirst()) else { return nil }
        let gens = table.keys.compactMap { $0.hasPrefix("M") ? Int($0.dropFirst()) : nil }.sorted(by: >)
        for g in gens where g <= n {
            if let v = lookup("M\(g)", variant, gpuCores) { return v }
        }
        return nil
    }

    private static func lookup(_ family: String, _ variant: ChipVariant, _ gpuCores: Int?) -> Double? {
        guard let e = table[family] else { return nil }
        switch variant {
        case .base: return e.base
        case .pro: return e.pro
        case .ultra: return e.ultra
        case .max:
            if let single = e.maxSingle { return single }
            guard let bins = e.max else { return nil }
            guard let cores = gpuCores else { return bins.low }
            return cores <= bins.lowGpuCores ? bins.low : bins.high
        }
    }
}
