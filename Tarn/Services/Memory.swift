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

    static let stopwords: Set<String> = ["the", "and", "for", "with", "that", "this", "you", "your", "are", "was", "what", "how",
                                          "can", "could", "would", "should", "about", "have", "has", "from", "into", "they", "them", "she", "his", "her",
                                          "him", "who", "why", "when", "where", "which", "will", "just", "like", "want", "need", "tell", "give", "make", "please"]

    static func keywords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// Same word, allowing simple endings: practice/practices/practising, dog/dogs, learn/learning.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        if s.count >= 7 { return l.hasPrefix(s.prefix(s.count - 2)) }
        if s.count >= 5 { return l.hasPrefix(s.prefix(s.count - 1)) }
        return s.count >= 3 && l.hasPrefix(s) && l.count - s.count <= 3
    }

    static func overlap(_ memory: String, _ query: Set<String>) -> Int {
        keywords(memory).filter { m in query.contains { sameWord(m, $0) } }.count
    }

    /// Memories ordered for the prompt: the ones that share words with the current message
    /// first (so the right facts are in view when they matter), then the most recent.
    static func ranked(_ items: [MemoryItem], for query: String) -> [MemoryItem] {
        let q = keywords(query)
        guard !q.isEmpty else { return items }
        let scored = items.enumerated().map { (i, m) in (m, overlap(m.text, q), i) }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    /// Diet and health facts are standing constraints: they matter for any food, travel or
    /// activity request even when the message shares no words with them ("dinner" vs "vegetarian").
    static let constraintCues = ["vegetarian", "vegan", "allerg", "diabet", "gluten", "lactose", "halal", "kosher", "jain", "keto",
                                 "pescatarian", "eggetarian", "doesn't eat", "does not eat", "no meat", "intoleran", "celiac", "coeliac",
                                 "pregnan", "blood pressure", "asthma", "wheelchair", "sober", "doesn't drink", "does not drink"]

    static func isConstraint(_ text: String) -> Bool {
        let t = text.lowercased()
        return constraintCues.contains { t.contains($0) }
    }

    /// The part of the system prompt that carries memories. Diet and health constraints come
    /// first, then facts that share words with the current message, then everything else, so the
    /// model uses the right ones and leaves the rest alone.
    static func promptSection(_ items: [MemoryItem], query: String = "") -> String? {
        guard !items.isEmpty else { return nil }
        let q = keywords(query)
        var constraints: [String] = [], relevant: [String] = [], other: [String] = []
        var used = 0
        for m in ranked(items, for: query) {
            used += m.text.count
            if used > 2400 || constraints.count + relevant.count + other.count >= 40 { break }
            if isConstraint(m.text) { constraints.append("- \(m.text)") }
            else if !q.isEmpty && overlap(m.text, q) > 0 { relevant.append("- \(m.text)") }
            else { other.append("- \(m.text)") }
        }
        var text = "What you remember about the user from earlier chats. Use it whenever it applies to what they are asking now: a meal idea must fit their diet, and a weekend plan can start from their city. Don’t bring up memories that have nothing to do with the request (like a pet or their job) just to sound personal, and don’t list what you remember unless asked."
        if !constraints.isEmpty { text += "\nAlways respect these whenever they apply:\n" + constraints.joined(separator: "\n") }
        if !relevant.isEmpty { text += "\nProbably relevant to this message:\n" + relevant.joined(separator: "\n") }
        if !other.isEmpty { text += "\n" + (constraints.isEmpty && relevant.isEmpty ? "" : "Other things you know:\n") + other.joined(separator: "\n") }
        return text
    }
}

/// Background memory extraction: after each answer, a short local prompt pulls durable facts
/// out of what the user just said.
enum MemoryExtraction {
    static func prompt(userText: String, known: [MemoryItem]) -> [[String: Any]] {
        let knownList = known.prefix(30).map { "- \($0.text)" }.joined(separator: "\n")
        let system = """
        You maintain a personal assistant's long-term memory about its user. Read the user's message and pull out lasting facts about the user that would help in future, unrelated conversations. Users often mention these in passing while asking for something else, so look inside requests and questions too.

        Worth saving: name, city or country, job, studies and exams, family members and pets (with names), health conditions, allergies and diet, hobbies and skills they are learning, things they own that they ask about (car, phone), language and style preferences, long-running goals and projects.
        Not worth saving: the request itself, passing moods ("I'm tired today"), one-off tasks, anything already known, and secrets (passwords, card or account numbers, exact addresses, ID numbers).

        Examples:
        User: My son Kabir has a cricket match Saturday, what should I pack for him?
        ["Has a son named Kabir who plays cricket."]
        User: Translate this to French: good morning
        []
        User: I'm a dentist in Kochi and I want to post more on Instagram, ideas?
        ["Is a dentist in Kochi.", "Wants to grow their Instagram presence."]
        User: I'm bored, tell me a joke
        []
        User: Please call me Sam, and I'm studying for my CA finals in May.
        ["Prefers to be called Sam.", "Is studying for CA finals in May."]

        Reply with only a JSON array of short third-person sentences, or [] if there is nothing new.
        """ + (knownList.isEmpty ? "" : "\n\nAlready known:\n\(knownList)")
        return [["role": "system", "content": system], ["role": "user", "content": String(userText.prefix(4000))]]
    }

    /// Pulls an array of strings out of a model reply, tolerating extra text around it and the
    /// single-quoted lists small models sometimes write.
    static func parse(_ reply: String) -> [String] {
        let cleaned = reply.replacing(/(?s)<think>.*?<\/think>/, with: "")
        guard let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start < end else { return [] }
        let list = String(cleaned[start...end])
        var items: [String]
        if let data = list.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            items = arr.compactMap { $0 as? String }
        } else {
            // ['Owns a car.', 'Likes the user\'s… ']: an apostrophe followed by a letter is part of a word.
            items = list.matches(of: /'((?:[^'\\]|\\.|'(?=[a-zA-Z]))*)'/).map { String($0.output.1).replacingOccurrences(of: "\\'", with: "'") }
        }
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(5).map { $0 }
    }

    /// Messages too short or purely task-like are skipped without asking the model.
    static func worthChecking(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.count >= 15 else { return false }
        let cues = ["i'm", "i am", "my ", "i live", "i work", "i study", "i have", "i like", "i love", "i prefer", "i hate", "i don't", "i do not",
                    "we're", "we are", "our ", "call me", "i've", "i was born", "i usually", "i always", "i never", "remember"]
        return cues.contains { t.contains($0) }
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
    let description = "Save a short fact about the user that will help in future chats: their name, work, where they live, family, ongoing projects or preferences. Write it as a standalone sentence, e.g. “Lives in Pune and works as a nurse.” Only save what the user says about themselves in their own messages; never infer facts from images, files, receipts or web results (a café receipt from Pune doesn’t mean they live in Pune). Never save passwords, card numbers or other secrets, and skip things that only matter for this chat."
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
