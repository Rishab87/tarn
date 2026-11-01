import Foundation

// MARK: - Settings

enum Tier: String, Codable, CaseIterable, Identifiable {
    case recommended, lighter, bigger
    var id: String { rawValue }
    var name: String {
        switch self {
        case .recommended: "Recommended"
        case .lighter: "Lighter"
        case .bigger: "Most capable"
        }
    }
    var blurb: String {
        switch self {
        case .recommended: "The best fit for your Mac. Smart, and fast enough to use while you browse."
        case .lighter: "Quicker and lighter on memory. Good for days with heavy apps open."
        case .bigger: "Smarter, but asks more of your Mac than is comfortable. Best with nothing else open."
        }
    }
}

enum ThemeChoice: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "System" : self == .light ? "Light" : "Dark" }
}

struct WaterStats: Codable, Equatable {
    var answers: Int = 0
    var ml: Double = 0
}

struct AppSettings: Codable, Equatable {
    var onboarded = false
    var theme: ThemeChoice = .system
    /// Download app updates in the background and install them on the next restart.
    var autoUpdate = true
    var activeTier: Tier = .recommended
    /// "What should Tarn know about you?" Read before every chat.
    var aboutYou = ""
    var webSearch = true
    /// Let the model think step by step before answering.
    var thinking = false
    /// Unload the model after this many idle minutes. 0 = never.
    var idleUnloadMinutes = 15
    var memoryGuard = true
    /// Remember facts about the user across chats (stored only on this Mac).
    var memoryEnabled = true
    var water = WaterStats()

    init() {}

    // Every field is optional on disk so older or hand-edited files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        onboarded = (try? c.decode(Bool.self, forKey: .onboarded)) ?? d.onboarded
        theme = (try? c.decode(ThemeChoice.self, forKey: .theme)) ?? d.theme
        autoUpdate = (try? c.decode(Bool.self, forKey: .autoUpdate)) ?? d.autoUpdate
        activeTier = (try? c.decode(Tier.self, forKey: .activeTier)) ?? d.activeTier
        aboutYou = String(((try? c.decode(String.self, forKey: .aboutYou)) ?? d.aboutYou).prefix(4000))
        webSearch = (try? c.decode(Bool.self, forKey: .webSearch)) ?? d.webSearch
        thinking = (try? c.decode(Bool.self, forKey: .thinking)) ?? d.thinking
        let idle = (try? c.decode(Int.self, forKey: .idleUnloadMinutes)) ?? d.idleUnloadMinutes
        idleUnloadMinutes = [0, 5, 15, 30, 60].contains(idle) ? idle : d.idleUnloadMinutes
        memoryGuard = (try? c.decode(Bool.self, forKey: .memoryGuard)) ?? d.memoryGuard
        memoryEnabled = (try? c.decode(Bool.self, forKey: .memoryEnabled)) ?? d.memoryEnabled
        var w = (try? c.decode(WaterStats.self, forKey: .water)) ?? d.water
        if w.answers < 0 || !w.ml.isFinite || w.ml < 0 { w = WaterStats() }
        water = w
    }
}

// MARK: - Hardware

struct Hardware: Equatable {
    var machineName: String
    var chip: String
    var chipFamily: String?
    var chipVariant: ChipVariant?
    var ramBytes: Int64
    var gpuCores: Int?
    /// What macOS lets the GPU keep resident (Metal's recommendedMaxWorkingSetSize).
    var gpuWorkingSetBytes: Int64?
    var freeDiskBytes: Int64
    var appleSilicon: Bool
    /// Unified memory bandwidth in GB/s from Apple's specs; nil for unknown chips.
    var bandwidthGBs: Double?

    var ramGB: Int { Int((Double(ramBytes) / 1_073_741_824).rounded()) }
    var chipShort: String { chip.replacingOccurrences(of: "Apple ", with: "") }
}

enum ChipVariant: String { case base, pro = "Pro", max = "Max", ultra = "Ultra" }

// MARK: - Models

enum ThinkingMode: String, Codable { case none, optional, always }

struct Sampling: Codable, Equatable {
    var temperature: Double
    var top_p: Double
    var top_k: Int
    var min_p: Double
    var presence_penalty: Double?
}

struct ModelFile: Codable, Equatable {
    let repo: String
    let path: String
    let revision: String
    let size: Int64
    let sha256: String
}

struct CatalogModel: Codable, Equatable, Identifiable {
    let id: String
    /// Real model name; shown only under "Details".
    let name: String
    /// Shown in brackets in the picker, e.g. "9B".
    let params: String
    let totalParamsB: Double
    let activeParamsB: Double
    /// Relative quality rank inside the catalog (higher is better).
    let quality: Int
    let file: ModelFile
    /// KV-cache bytes per token of context with q8_0 caches (measured with llama.cpp).
    let kvBytesPerToken: Int64
    /// Fixed runtime buffers beyond weights and KV cache (measured).
    let overheadBytes: Int64
    let maxContext: Int
    let thinking: ThinkingMode
    let license: String
    let licenseUrl: String
    let sampling: Sampling
    let thinkingSampling: Sampling?
    /// Sent with thinking on, for models whose template supports it (Qwen3.8 defaults to "xhigh").
    let reasoningEffort: String?
    /// Vision projector (mmproj) that lets the model read images. Downloaded after the model.
    let vision: ModelFile?

    var visionURL: URL? { vision.map { URL(string: "https://huggingface.co/\($0.repo)/resolve/\($0.revision)/\($0.path)")! } }

    var downloadURL: URL { URL(string: "https://huggingface.co/\(file.repo)/resolve/\(file.revision)/\(file.path)")! }
    /// Moving URL used to notice upstream fixes to the same file.
    var latestURL: URL { URL(string: "https://huggingface.co/\(file.repo)/resolve/main/\(file.path)")! }
    var pageURL: URL { URL(string: "https://huggingface.co/\(file.repo)")! }
}

struct ModelPick: Equatable {
    let model: CatalogModel
    let contextTokens: Int
    let footprintBytes: Int64
    let estTokensPerSec: Double?
}

struct Picks: Equatable {
    var recommended: ModelPick?
    var lighter: ModelPick?
    /// A stronger model than this Mac comfortably runs, offered at the user's own risk.
    var bigger: ModelPick? = nil
    var budgetBytes: Int64

    func pick(_ tier: Tier) -> ModelPick? {
        switch tier {
        case .recommended: recommended
        case .lighter: lighter
        case .bigger: bigger
        }
    }
    func tier(of modelId: String?) -> Tier? {
        guard let modelId else { return nil }
        if recommended?.model.id == modelId { return .recommended }
        if lighter?.model.id == modelId { return .lighter }
        if bigger?.model.id == modelId { return .bigger }
        return nil
    }
}

struct InstalledModel: Codable, Equatable {
    let id: String
    var fileName: String
    var sha256: String
    var size: Int64
    var installedAt: Date
    var visionFileName: String? = nil
}

struct DownloadProgress: Equatable {
    let modelId: String
    var received: Int64
    var total: Int64
    var bytesPerSec: Double
    var isUpdate: Bool
    /// The image add-on (vision projector) rather than the model itself.
    var isVision = false
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

enum DownloadState: Equatable {
    case idle
    case downloading(DownloadProgress)
    case paused(DownloadProgress)
    case verifying(DownloadProgress)
    case failed(modelId: String, message: String, isVision: Bool = false)

    var modelId: String? {
        switch self {
        case .idle: nil
        case .downloading(let p), .paused(let p), .verifying(let p): p.modelId
        case .failed(let id, _, _): id
        }
    }
    /// True for the image add-on download, which runs in the background after the model.
    var isVision: Bool {
        switch self {
        case .idle: false
        case .downloading(let p), .paused(let p), .verifying(let p): p.isVision
        case .failed(_, _, let v): v
        }
    }
    var progress: DownloadProgress? {
        switch self {
        case .downloading(let p), .paused(let p), .verifying(let p): p
        default: nil
        }
    }
}

struct ModelUpdate: Equatable, Identifiable {
    enum Kind: String { case file, replacement }
    let modelId: String
    let kind: Kind
    /// For .replacement: the model the new catalog recommends instead.
    let replacementId: String?
    let sizeBytes: Int64
    let sha256: String?
    var id: String { modelId + kind.rawValue }
}

enum EngineState: Equatable {
    case stopped
    case starting(modelId: String)
    case ready(modelId: String, contextTokens: Int)
    case failed(modelId: String?, message: String)

    var modelId: String? {
        switch self {
        case .stopped: nil
        case .starting(let id), .ready(let id, _): id
        case .failed(let id, _): id
        }
    }
}

// MARK: - Chats

struct Attachment: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable { case text, pdf, image }
    var id: String
    var name: String
    var kind: Kind
    var size: Int64
    /// Extracted text the model reads (empty for images).
    var text: String
    var truncated: Bool = false
    /// For images: file name inside the attachments folder (a downscaled JPEG).
    var file: String? = nil
}

struct MemoryItem: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var createdAt: Date
}

enum ToolStatus: String, Codable { case running, awaitingApproval = "awaiting-approval", done, error, denied }

enum ApprovalDecision { case deny, once, chat }

struct ApprovalRequest: Codable, Equatable {
    var title: String
    /// Exactly what will happen: the command, the file and its new contents, the connector call.
    var detail: String
}

struct ToolBlock: Codable, Equatable {
    var id: String
    var name: String
    /// Past-tense label for the transcript: "Searched the web for …"
    var label: String
    var args: String
    var status: ToolStatus
    var result: String?
    var approval: ApprovalRequest?
}

enum Block: Codable, Equatable {
    case text(String)
    case thinking(text: String, ms: Int)
    case tool(ToolBlock)

    private enum CodingKeys: String, CodingKey { case type, text, ms, tool }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "thinking": self = .thinking(text: try c.decode(String.self, forKey: .text), ms: (try? c.decode(Int.self, forKey: .ms)) ?? 0)
        case "tool": self = .tool(try c.decode(ToolBlock.self, forKey: .tool))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown block type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .thinking(let t, let ms):
            try c.encode("thinking", forKey: .type)
            try c.encode(t, forKey: .text)
            try c.encode(ms, forKey: .ms)
        case .tool(let b):
            try c.encode("tool", forKey: .type)
            try c.encode(b, forKey: .tool)
        }
    }
}

enum Role: String, Codable { case user, assistant }
enum MessageStatus: String, Codable { case streaming, done, stopped, error }

struct Message: Codable, Equatable, Identifiable {
    var id: String
    var role: Role
    var createdAt: Date
    // user
    var text: String = ""
    var attachments: [Attachment]? = nil
    // assistant
    var blocks: [Block] = []
    var status: MessageStatus? = nil
    var error: String? = nil
    var modelId: String? = nil
    var tokens: Int? = nil
    var ms: Int? = nil

    var visibleText: String {
        role == .user ? text : blocks.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n\n")
    }
}

struct Chat: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var pinned: Bool = false
    /// Folder the user shared with Tarn for this chat.
    var folder: String? = nil
    var messages: [Message] = []

    var isAnswering: Bool { messages.contains { $0.role == .assistant && $0.status == .streaming } }

    var preview: String {
        for m in messages.reversed() {
            let t = m.visibleText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty { return String(t.prefix(140)) }
        }
        return ""
    }
}

struct ChatSummary: Equatable, Identifiable {
    var id: String
    var title: String
    var updatedAt: Date
    var pinned: Bool
    var preview: String

    init(_ c: Chat) {
        id = c.id
        title = c.title
        updatedAt = c.updatedAt
        pinned = c.pinned
        preview = c.preview
    }
}

// MARK: - Connectors, skills, alerts

struct ConnectorConfig: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case stdio, http }
    var id: String
    var name: String
    var kind: Kind
    var command: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String = ""
    var headers: [String: String] = [:]
    var enabled: Bool

    init(id: String, name: String, kind: Kind, command: String = "", args: [String] = [], env: [String: String] = [:],
         url: String = "", headers: [String: String] = [:], enabled: Bool) {
        self.id = id; self.name = name; self.kind = kind; self.command = command; self.args = args
        self.env = env; self.url = url; self.headers = headers; self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

struct ConnectorStatus: Equatable {
    enum State: Equatable { case off, connecting, connected, failed(String) }
    var state: State
    var tools: [String] = []
}

struct Skill: Equatable, Identifiable {
    var name: String
    var description: String
    var builtIn: Bool
    var enabled: Bool
    var dir: URL
    var id: String { name }
}

struct MemoryAlert: Equatable {
    var critical: Bool
    var onLighter: Bool
    var engineGB: Double?
}

struct ImportResult {
    var chats = 0
    var skipped = 0
    var skills = 0
    var connectors = 0
}

func newId() -> String {
    let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    var bytes = [UInt8](repeating: 0, count: 6)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return t + bytes.map { String(format: "%02x", $0) }.joined()
}
