import Foundation

/// Facts Tarn remembers about the user across chats. Stored only on this Mac, in memory.json;
/// visible and deletable in Settings → Memory.
enum MemoryStore {
    static let maxItems = 200
    static let maxLength = 300

    static var file: URL { Paths.data.appendingPathComponent("memory.json") }

    static func load() -> [MemoryItem] {
        JSONFile.read([MemoryItem].self, from: file) ?? []
    }

    static func save(_ items: [MemoryItem]) {
        try? JSONFile.write(items, to: file)
    }

    /// Cleans up a fact before storing it. Returns nil for things that shouldn't be kept.
    static func normalize(_ raw: String) -> String? {
        let text = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return nil }
        // Never keep secrets, even if asked: long digit runs (cards, accounts) and credentials.
        if text.firstMatch(of: /\d[\d -]{11,}\d/) != nil { return nil }
        if text.range(of: #"\b(password|passcode|pin code|cvv|otp|api key|secret key)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return String(text.prefix(maxLength))
    }

    /// Adds a fact unless an equivalent one is already stored. Newest first.
    static func adding(_ text: String, to items: [MemoryItem]) -> (items: [MemoryItem], added: Bool) {
        let key = text.lowercased().filter { $0.isLetter || $0.isNumber }
        if items.contains(where: { $0.text.lowercased().filter { $0.isLetter || $0.isNumber } == key }) { return (items, false) }
        var out = [MemoryItem(id: newId(), text: text, createdAt: Date())] + items
        if out.count > maxItems { out = Array(out.prefix(maxItems)) }
        return (out, true)
    }

    /// Removes facts containing every word of `query` (case-insensitive).
    static func removing(matching query: String, from items: [MemoryItem]) -> (items: [MemoryItem], removed: Int) {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return (items, 0) }
        let keep = items.filter { item in
            let t = item.text.lowercased()
            return !words.allSatisfy { t.contains($0) }
        }
        return (keep, items.count - keep.count)
    }

    /// The part of the system prompt that carries memories: newest first, capped in size.
    static func promptSection(_ items: [MemoryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        var lines: [String] = []
        var used = 0
        for m in items {
            used += m.text.count
            if used > 2400 || lines.count >= 40 { break }
            lines.append("- \(m.text)")
        }
        return "What you remember about the user from earlier chats (use it naturally; don’t recite it unless asked):\n" + lines.joined(separator: "\n")
    }
}

/// Keyword search over earlier chats, for the search_past_chats tool.
enum PastChats {
    static func search(_ query: String, in chats: [Chat], excluding chatId: String?) -> String {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        guard !words.isEmpty else { return "Give a few words to search for." }
        var hits: [(chat: Chat, score: Int, excerpt: String)] = []
        for chat in chats where chat.id != chatId && !chat.messages.isEmpty {
            var best: (score: Int, text: String) = (0, "")
            for m in chat.messages {
                let text = m.visibleText
                let lower = text.lowercased()
                let score = words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) } + (chat.title.lowercased().contains(words[0]) ? 1 : 0)
                if score > best.score { best = (score, text) }
            }
            guard best.score > 0 else { continue }
            hits.append((chat, best.score, excerpt(best.text, around: words)))
        }
        let top = hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.chat.updatedAt > $1.chat.updatedAt }.prefix(5)
        if top.isEmpty { return "No earlier chats mention that." }
        return top.map { h in
            "Chat “\(h.chat.title)” (\(h.chat.updatedAt.formatted(date: .abbreviated, time: .omitted))):\n\(h.excerpt)"
        }.joined(separator: "\n\n")
    }

    static func excerpt(_ text: String, around words: [String]) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lower = flat.lowercased()
        guard let r = words.lazy.compactMap({ lower.range(of: $0) }).first else { return String(flat.prefix(400)) }
        let start = flat.index(r.lowerBound, offsetBy: -200, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 300, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

struct RememberTool: Tool {
    let save: @Sendable (String) async -> String
    let name = "remember"
    let description = "Save a short fact about the user that will help in future chats: their name, work, where they live, family, ongoing projects or preferences. Write it as a standalone sentence, e.g. “Lives in Pune and works as a nurse.” Never save passwords, card numbers or other secrets, and skip things that only matter for this chat."
    var parameters: [String: Any] { schema(["fact": ["type": "string", "description": "The fact to remember, as one short sentence."]], required: ["fact"]) }
    func label(_ args: [String: Any]) -> String { "Saved to memory: “\((args["fact"] as? String ?? "").prefix(90))”" }
    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String { await save(try args.string("fact")) }
}

struct ForgetTool: Tool {
    let forget: @Sendable (String) async -> String
    let name = "forget"
    let description = "Delete saved memories when the user asks you to forget something. Pass a few words that appear in the memory."
    var parameters: [String: Any] { schema(["what": ["type": "string", "description": "Words from the memory to delete."]], required: ["what"]) }
    func label(_ args: [String: Any]) -> String { "Forgot “\((args["what"] as? String ?? "").prefix(60))”" }
    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String { await forget(try args.string("what")) }
}

struct SearchPastChatsTool: Tool {
    let search: @Sendable (String, String) async -> String
    let name = "search_past_chats"
    let description = "Search the user’s earlier conversations with you (stored on this Mac) when they refer to something you discussed before."
    var parameters: [String: Any] { schema(["query": ["type": "string", "description": "Words to look for."]], required: ["query"]) }
    func label(_ args: [String: Any]) -> String { "Searched earlier chats for “\((args["query"] as? String ?? "").prefix(60))”" }
    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String { await search(try args.string("query"), ctx.chat.id) }
}
