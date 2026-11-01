import AppKit
import Foundation
import Testing
import ZIPFoundation
@testable import Tarn

private let GiB: Int64 = 1 << 30

@Suite("Model picks per Mac")
struct ModelPickTests {
    // gpuWorkingSet fractions as reported by macOS 26 (see docs/MODELS.md).
    func picks(ram: Int64, ws: Double, bw: Double?) -> Picks {
        ModelFit.picks(ramBytes: ram * GiB, gpuWorkingSetBytes: Int64(Double(ram * GiB) * ws), bandwidthGBs: bw)
    }

    @Test func catalogLoads() {
        #expect(Catalog.all.count == 6)
        #expect(Catalog.all.allSatisfy { $0.file.sha256.count == 64 && $0.file.size > 0 })
    }

    @Test func eightGigM1() {
        let p = picks(ram: 8, ws: 0.67, bw: 68)
        #expect(p.recommended?.model.id == "qwen3.5-4b")
        #expect(p.lighter?.model.id == "qwen3.5-2b")
        #expect(p.recommended!.footprintBytes <= p.budgetBytes)
    }

    @Test func eightGigMacBookNeo() {
        let p = picks(ram: 8, ws: 0.67, bw: Chips.bandwidth(family: "A18", variant: .pro, gpuCores: nil))
        #expect(p.recommended?.model.id == "qwen3.5-4b")
    }

    @Test func sixteenGigM5() {
        let p = picks(ram: 16, ws: 0.74, bw: 153)
        #expect(p.recommended?.model.id == "qwen3.5-9b")
        #expect(p.lighter?.model.id == "qwen3.5-4b")
        // Leaves at least half the Mac's memory for everything else.
        #expect(p.recommended!.footprintBytes <= 8 * GiB)
    }

    @Test func twentyFourGigM4Pro() {
        let p = picks(ram: 24, ws: 0.74, bw: 273)
        #expect(p.recommended?.model.id == "qwen3.5-9b")
    }

    @Test func thirtyTwoGigProGetsTheFastMoE() {
        // M3 Pro: the dense 27B would crawl (~6 tokens/s), so the 3B-active MoE wins.
        let p = picks(ram: 32, ws: 0.78, bw: 150)
        #expect(p.recommended?.model.id == "qwen3.6-35b-a3b")
        #expect(p.lighter?.model.id == "qwen3.5-9b")
    }

    @Test func m5ProStaysOnTheMoE() {
        let p = picks(ram: 36, ws: 0.78, bw: 307)
        #expect(p.recommended?.model.id == "qwen3.6-35b-a3b")
    }

    @Test func maxChipsGetTheSmartestModel() {
        let m4max = picks(ram: 32, ws: 0.78, bw: 546)
        #expect(m4max.recommended?.model.id == "qwen3.8-27b")
        #expect(m4max.lighter?.model.id == "qwen3.5-9b")
        let m5max = picks(ram: 64, ws: 0.8, bw: 614)
        #expect(m5max.recommended?.model.id == "qwen3.8-27b")
    }

    @Test func mostCapableOption() {
        // 16 GB: the 3-bit 35B fits in RAM (tight), so it's offered rather than paging the 4-bit one.
        let m5 = picks(ram: 16, ws: 0.74, bw: 153)
        #expect(m5.bigger?.model.id == "qwen3.6-35b-a3b-compact")
        #expect(ModelFit.biggerWarning(m5.bigger!, ramBytes: 16 * GiB, budgetBytes: m5.budgetBytes).contains("Other apps may slow down"))
        // 24 GB M4 Pro: the full 4-bit 35B fits and is fast.
        #expect(picks(ram: 24, ws: 0.74, bw: 273).bigger?.model.id == "qwen3.6-35b-a3b")
        // 8 GB: the 9B fits in RAM, just not comfortably.
        let m1 = picks(ram: 8, ws: 0.67, bw: 68)
        #expect(m1.bigger?.model.id == "qwen3.5-9b")
        // M3 Pro 32 GB: the dense 27B is smarter but slow there.
        let pro = picks(ram: 32, ws: 0.78, bw: 150)
        #expect(pro.bigger?.model.id == "qwen3.8-27b")
        #expect(ModelFit.biggerWarning(pro.bigger!, ramBytes: 32 * GiB, budgetBytes: pro.budgetBytes).contains("words a second"))
        // Max chips already get the strongest model: no "Most capable" option.
        #expect(picks(ram: 32, ws: 0.78, bw: 546).bigger == nil)
    }

    @Test func tooLittleMemory() {
        let p = picks(ram: 4, ws: 0.67, bw: 68)
        #expect(p.recommended == nil)
    }

    @Test func unknownChipStillGetsAPick() {
        let p = picks(ram: 16, ws: 0.74, bw: nil)
        #expect(p.recommended?.model.id == "qwen3.5-9b")
    }
}

@Suite("Apple Silicon bandwidth")
struct ChipTests {
    @Test func parsing() {
        #expect(Chips.parse("Apple M5").family == "M5")
        #expect(Chips.parse("Apple M5").variant == .base)
        #expect(Chips.parse("Apple M4 Max").variant == .max)
        #expect(Chips.parse("Apple A18 Pro").family == "A18")
        #expect(Chips.parse("Intel(R) Core(TM) i9").family == nil)
    }

    @Test func bins() {
        #expect(Chips.bandwidth(family: "M5", variant: .base, gpuCores: 10) == 153)
        #expect(Chips.bandwidth(family: "M4", variant: .max, gpuCores: 40) == 546)
        #expect(Chips.bandwidth(family: "M4", variant: .max, gpuCores: 32) == 410)
        #expect(Chips.bandwidth(family: "M1", variant: .max, gpuCores: 24) == 400)
        // A newer chip than the table assumes at least the newest known chip of its tier.
        #expect(Chips.bandwidth(family: "M7", variant: .pro, gpuCores: nil) == 307)
    }
}

@Suite("Streaming parser")
struct SSETests {
    @Test func content() {
        let l = SSE.parse(#"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        #expect(l == .chunk(StreamChunk(content: "Hi")))
    }

    @Test func reasoningAndToolCalls() {
        guard case .chunk(let c) = SSE.parse(#"data: {"choices":[{"delta":{"reasoning_content":"hmm","tool_calls":[{"index":0,"id":"c1","function":{"name":"web_search","arguments":"{\"q"}}]}}]}"#) else {
            Issue.record("not a chunk"); return
        }
        #expect(c.reasoning == "hmm")
        #expect(c.toolCalls == [ToolCallDelta(index: 0, id: "c1", name: "web_search", arguments: "{\"q")])
    }

    @Test func doneAndNoise() {
        #expect(SSE.parse("data: [DONE]") == .done)
        #expect(SSE.parse(": keep-alive") == .ignore)
        #expect(SSE.parse("data: {broken") == .ignore)
    }

    @Test func errors() {
        guard case .chunk(let c) = SSE.parse(#"data: {"error":{"message":"boom"}}"#) else { Issue.record("not a chunk"); return }
        #expect(c.error == "boom")
    }
}

@Suite("Web tools")
struct WebTests {
    @Test func duckDuckGo() {
        let html = """
        <div class="result"><a rel="nofollow" class="result__a" href="https://example.com/a?x=1&amp;y=2">Best <b>time</b> to visit</a>
        <a class="result__snippet" href="#">Visit in <b>June</b> &amp; July.</a></div>
        <div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Ficeland.is%2Fguide&amp;rut=1">Guide</a></div>
        """
        let r = DuckDuckGo.parse(html)
        #expect(r.count == 2)
        #expect(r[0] == SearchResult(title: "Best time to visit", url: "https://example.com/a?x=1&y=2", snippet: "Visit in June & July."))
        #expect(r[1].url == "https://iceland.is/guide")
    }

    @Test func htmlToText() {
        let t = HTMLText.toText("<html><head><title>T &amp; Co</title><script>evil()</script></head><body><nav>menu</nav><h2>Hello</h2><p>One&nbsp;two</p><ul><li>a</li><li>b</li></ul></body></html>")
        #expect(t.hasPrefix("T & Co"))
        #expect(t.contains("## Hello"))
        #expect(t.contains("• a"))
        #expect(!t.contains("evil"))
        #expect(!t.contains("menu"))
    }

    @Test func privateAddresses() {
        for ip in ["10.0.0.1", "127.0.0.1", "192.168.1.1", "172.16.5.4", "169.254.1.1", "100.64.0.1", "::1", "fd00::1", "fe80::1", "::ffff:10.0.0.1"] {
            #expect(NetGuard.isPrivate(ip), "\(ip) should be private")
        }
        for ip in ["8.8.8.8", "172.32.0.1", "1.1.1.1", "2606:4700::1111"] {
            #expect(!NetGuard.isPrivate(ip), "\(ip) should be public")
        }
    }

    @Test func blocksLocalURLs() {
        #expect(throws: ToolFailure.self) { try NetGuard.checkPublic("http://localhost:8080") }
        #expect(throws: ToolFailure.self) { try NetGuard.checkPublic("http://192.168.0.1/admin") }
        #expect(throws: ToolFailure.self) { try NetGuard.checkPublic("file:///etc/passwd") }
    }
}

@Suite("Folder access")
struct FolderTests {
    @Test func staysInside() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("tarn-folder-\(UUID().uuidString)")
        let root = base.appendingPathComponent("shared")
        let outside = base.appendingPathComponent("secret")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("key.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        defer { try? fm.removeItem(at: base) }

        let r = root.resolvingSymlinksInPath()
        #expect(try FolderAccess.inside(r, "sub", mustExist: true).lastPathComponent == "sub")
        #expect(try FolderAccess.inside(r, "new/file.txt", mustExist: false).lastPathComponent == "file.txt")
        #expect(throws: ToolFailure.self) { try FolderAccess.inside(r, "../secret/key.txt", mustExist: true) }
        #expect(throws: ToolFailure.self) { try FolderAccess.inside(r, "link/key.txt", mustExist: true) }
        #expect(throws: ToolFailure.self) { try FolderAccess.inside(r, "/etc/passwd", mustExist: true) }
    }
}

@Suite("Skills")
struct SkillTests {
    @Test func frontMatter() {
        let (meta, body) = Skills.parseFrontMatter("---\nname: Email Writer\ndescription: \"Write emails\"\nlong: >\n  one\n  two\n---\n\nDo it.\n")
        #expect(meta["name"] == "Email Writer")
        #expect(meta["description"] == "Write emails")
        #expect(meta["long"] == "one two")
        #expect(body.trimmingCharacters(in: .whitespacesAndNewlines) == "Do it.")
        #expect(Skills.slug("Email Writer!") == "email-writer")
    }

    @Test func builtInsLoad() {
        let names = Set(Skills.list().filter(\.builtIn).map(\.name))
        #expect(names == ["email-writer", "document-summary", "study-buddy"])
    }
}

@Suite("Prompt")
struct PromptTests {
    @Test func historyWithTools() {
        let user = Message(id: "u1", role: .user, createdAt: Date(), text: "weather?")
        var ai = Message(id: "a1", role: .assistant, createdAt: Date())
        ai.blocks = [
            .thinking(text: "let me search", ms: 10),
            .tool(ToolBlock(id: "c1", name: "web_search", label: "Searched", args: "{\"query\":\"weather\"}", status: .done, result: "Sunny")),
            .text("It's sunny."),
        ]
        let h = Prompt.history([user, ai])
        #expect(h.count == 4)
        #expect(h[0]["role"] as? String == "user")
        #expect(h[1]["role"] as? String == "assistant")
        #expect((h[1]["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(h[2]["role"] as? String == "tool")
        #expect(h[2]["content"] as? String == "Sunny")
        #expect(h[3]["content"] as? String == "It's sunny.")
        #expect(!h.contains { ($0["content"] as? String)?.contains("let me search") == true })
    }

    @Test func fitDropsOldTurns() {
        var msgs: [[String: Any]] = []
        for i in 0..<20 {
            msgs.append(["role": "user", "content": String(repeating: "q\(i) ", count: 200)])
            msgs.append(["role": "assistant", "content": String(repeating: "a\(i) ", count: 200)])
        }
        msgs.append(["role": "user", "content": "last question"])
        let fitted = Prompt.fit(system: "sys", history: msgs, toolsJSONLength: 0, budget: 1500)
        #expect(fitted.first?["role"] as? String == "system")
        #expect(fitted[1]["role"] as? String == "user")
        #expect(fitted.last?["content"] as? String == "last question")
        #expect(Prompt.estimateTokens(fitted) <= 1500)
    }

    @Test func attachmentsAreCapped() {
        let a = Attachment(id: "f", name: "big.txt", kind: .text, size: 10, text: String(repeating: "x", count: 5000))
        let m = Message(id: "u", role: .user, createdAt: Date(), text: "read", attachments: [a])
        let c = Prompt.userContent(m, attachmentChars: 1000)
        #expect(c.contains("only the beginning fits"))
        #expect(c.count < 1400)
    }
}

@Suite("Backup")
struct BackupTests {
    @Test func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tarn-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("b.zip")
        var chat = Chat(id: "abc123", title: "Trip", createdAt: Date(), updatedAt: Date())
        chat.messages = [Message(id: "m1", role: .user, createdAt: Date(), text: "plan it")]
        var s = AppSettings()
        s.aboutYou = "I'm Sam"
        let conn = ConnectorConfig(id: "c1", name: "Files", kind: .stdio, command: "npx", args: ["-y", "x"], enabled: true)
        try Backup.export(to: zip, chats: [chat], settings: s, connectors: [conn])
        let back = try Backup.read(zip)
        #expect(back.chats.map(\.title) == ["Trip"])
        #expect(back.settings?.aboutYou == "I'm Sam")
        #expect(back.settings?.onboarded == false)
        #expect(back.connectors.first?.command == "npx")
    }

    @Test func rejectsNonBackups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tarn-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notZip = dir.appendingPathComponent("x.zip")
        try Data("hello".utf8).write(to: notZip)
        #expect(throws: ToolFailure.self) { try Backup.read(notZip) }

        let otherZip = dir.appendingPathComponent("y.zip")
        let a = try Archive(url: otherZip, accessMode: .create)
        let d = Data("{}".utf8)
        try a.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(d.count)) { pos, size in d.subdata(in: Int(pos)..<Int(pos) + size) }
        #expect(throws: ToolFailure.self) { try Backup.read(otherZip) }
    }

    @Test func skillPathsCannotEscape() {
        let n = Backup.restoreSkills([("../../escape/SKILL.md", Data("x".utf8)), ("ok-skill/../../../evil.txt", Data("x".utf8))])
        #expect(n == 0)
        #expect(!FileManager.default.fileExists(atPath: Paths.skills.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }
}

@Suite("Formatting and settings")
struct MiscTests {
    @Test func water() {
        #expect(Water.format(0) == "0 mL")
        #expect(Water.format(999) == "999 mL")
        #expect(Water.format(1100) == "1.1 L")
        #expect(Water.format(250_000) == "250 L")
    }

    @Test func settingsDecodeDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"theme":"neon","idleUnloadMinutes":7,"water":{"answers":-1,"ml":5}}"#.utf8))
        #expect(s.theme == .system)
        #expect(s.idleUnloadMinutes == 15)
        #expect(s.water == WaterStats())
        #expect(s.webSearch)
    }

    @Test func splitsCommands() {
        #expect(splitArgs(#"npx -y "@scope/server name" '/a b'"#) == ["npx", "-y", "@scope/server name", "/a b"])
    }
}

@Suite("Memory")
struct MemoryTests {
    @Test func keepsFactsButNeverSecrets() {
        #expect(MemoryStore.normalize("Lives in Pune and is vegetarian.") == "Lives in Pune and is vegetarian.")
        #expect(MemoryStore.normalize("My card is 4111 1111 1111 1111") == nil)
        #expect(MemoryStore.normalize("wifi password is hunter2") == nil)
        #expect(MemoryStore.normalize("  ") == nil)
    }

    @Test func dedupesAndForgets() {
        var items = MemoryStore.adding("Name is Sam.", to: []).items
        let again = MemoryStore.adding("name is sam", to: items)
        #expect(!again.added)
        items = MemoryStore.adding("Works as a nurse in Pune.", to: items).items
        #expect(items.first?.text == "Works as a nurse in Pune.")
        let r = MemoryStore.removing(matching: "nurse", from: items)
        #expect(r.removed == 1 && r.items.count == 1)
        #expect(MemoryStore.promptSection(items)?.contains("- Name is Sam.") == true)
    }

    @Test func extractionParsingAndCues() {
        #expect(MemoryExtraction.parse("Sure! [\"Is a nurse.\", \"Has a dog named Bruno.\"]") == ["Is a nurse.", "Has a dog named Bruno."])
        #expect(MemoryExtraction.parse("<think>hmm</think>[]").isEmpty)
        #expect(MemoryExtraction.parse("nothing here").isEmpty)
        #expect(MemoryExtraction.parse("['Owns a 2019 Honda City.', 'Is learning the guitar that's acoustic.']") == ["Owns a 2019 Honda City.", "Is learning the guitar that's acoustic."])
        #expect(MemoryExtraction.worthChecking("I work night shifts as a nurse in Pune"))
        #expect(!MemoryExtraction.worthChecking("What's 2+2?"))
    }

    @Test func recallsRelevantMemoriesFirst() {
        var items: [MemoryItem] = []
        for t in ["Has a dog named Bruno.", "Is vegetarian.", "Lives in Pune.", "Works as a nurse."] { items = MemoryStore.adding(t, to: items).items }
        let ranked = MemoryStore.ranked(items, for: "Suggest a vegetarian dinner recipe")
        #expect(ranked.first?.text == "Is vegetarian.")
        let section = MemoryStore.promptSection(items + MemoryStore.adding("Is learning fingerstyle guitar and practices daily.", to: []).items, query: "What should I practice this week?") ?? ""
        #expect(section.contains("Always respect these whenever they apply:\n- Is vegetarian.\nProbably relevant to this message:\n- Is learning fingerstyle guitar and practices daily.\nOther things you know:"))
        #expect(MemoryStore.promptSection(items, query: "walk my dogs")?.contains("relevant to this message:\n- Has a dog named Bruno.") == true)
        #expect(MemoryStore.sameWord("learn", "learning") && MemoryStore.sameWord("practice", "practising") && !MemoryStore.sameWord("cat", "category"))
    }

    @Test func searchesPastChats() {
        var a = Chat(id: "a1", title: "Goa trip", createdAt: Date(), updatedAt: Date())
        a.messages = [Message(id: "m", role: .user, createdAt: Date(), text: "Book a beach shack in Goa for December")]
        var b = Chat(id: "b1", title: "Tax", createdAt: Date(), updatedAt: Date())
        b.messages = [Message(id: "n", role: .user, createdAt: Date(), text: "File my taxes")]
        let out = PastChats.search("goa beach", in: [a, b], excluding: "b1")
        #expect(out.contains("Goa trip"))
        #expect(!out.contains("Tax"))
        #expect(PastChats.search("goa", in: [a], excluding: "a1") == "No earlier chats mention that.")
    }
}

@Suite("Images")
struct ImageTests {
    @Test func recentImagesSentAsPixelsOlderAsNotes() {
        func msg(_ id: String, image: Bool) -> Message {
            Message(id: id, role: .user, createdAt: Date(), text: "look",
                    attachments: image ? [Attachment(id: "i\(id)", name: "\(id).png", kind: .image, size: 1, text: "", file: "i\(id).jpg")] : nil)
        }
        let msgs = [msg("1", image: true), msg("2", image: true), msg("3", image: true)]
        let h = Prompt.history(msgs, imageDataURL: { _ in "data:image/jpeg;base64,AAAA" })
        #expect(h[0]["content"] is String)
        #expect((h[0]["content"] as? String)?.contains("[An image was attached here: 1.png]") == true)
        #expect((h[2]["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true)
        #expect(Prompt.needsVision(msgs))
        #expect(!Prompt.needsVision([msg("4", image: false)]))
        #expect(Prompt.estimateTokens(h) > 2000)
    }

    @Test func everyModelHasVision() {
        #expect(Catalog.all.allSatisfy { $0.vision?.sha256.count == 64 })
    }
}

@Suite("Chat folders")
struct ChatGroupTests {
    /// Each test gets its own chats folder and groups.json, so parallel tests never collide.
    func scratch() throws -> (store: ChatStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tarn-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chats"), withIntermediateDirectories: true)
        return (reopen(root), root)
    }

    /// A fresh store over the same files: what the next launch would see.
    func reopen(_ root: URL) -> ChatStore {
        ChatStore(dir: root.appendingPathComponent("chats"), groupsFile: root.appendingPathComponent("groups.json"))
    }

    func chat(_ id: String, _ title: String, text: String = "hello", updated: Date = Date()) -> Chat {
        var c = Chat(id: id, title: title, createdAt: updated, updatedAt: updated)
        c.messages = [Message(id: "m-\(id)", role: .user, createdAt: updated, text: text)]
        return c
    }

    @Test func createRenameDelete() throws {
        let (store, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        store.save(chat("a1", "Goa trip"))
        store.save(chat("b1", "Taxes"))

        #expect(store.createGroup("  \n ") == nil)
        let work = try #require(store.createGroup("  Work\nstuff  "))
        #expect(work.name == "Work stuff")
        store.createGroup("archive")
        #expect(store.groups.map(\.name) == ["archive", "Work stuff"])

        store.renameGroup(work.id, "Admin")
        store.renameGroup(work.id, "   ")
        #expect(store.groups.map(\.name) == ["Admin", "archive"])

        #expect(store.move("a1", to: work.id))
        #expect(store.move("b1", to: work.id))
        store.deleteGroup(work.id)
        #expect(store.groups.map(\.name) == ["archive"])
        #expect(store.chats.count == 2)
        #expect(store.chats.values.allSatisfy { $0.groupId == nil })

        // On disk too: the folder is gone and its chats are back in the main list.
        let next = reopen(root)
        #expect(next.groups.map(\.name) == ["archive"])
        #expect(Set(next.summaries.map(\.id)) == ["a1", "b1"])
        #expect(next.chats.values.allSatisfy { $0.groupId == nil })
    }

    @Test func moveInAndOut() throws {
        let (store, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        store.save(chat("a1", "Goa trip"))
        let trips = try #require(store.createGroup("Trips"))

        #expect(store.move("a1", to: trips.id))
        #expect(!store.move("a1", to: trips.id))
        #expect(!store.move("a1", to: "no-such-folder"))
        #expect(!store.move("missing", to: trips.id))
        #expect(store.chats["a1"]?.groupId == trips.id)
        #expect(reopen(root).chats["a1"]?.groupId == trips.id)

        #expect(store.move("a1", to: nil))
        #expect(store.chats["a1"]?.groupId == nil)
        #expect(reopen(root).chats["a1"]?.groupId == nil)
    }

    @Test func collapsedStateIsRemembered() throws {
        let (store, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let g = try #require(store.createGroup("Work"))
        #expect(!g.collapsed)
        store.setGroupCollapsed(g.id, true)
        #expect(reopen(root).groups.first?.collapsed == true)
        store.setGroupCollapsed(g.id, false)
        #expect(reopen(root).groups.first?.collapsed == false)
    }

    @Test func oldChatsDecodeWithoutAFolder() throws {
        // A chat file from before folders existed. `folder` is the shared folder on disk, not a ChatGroup.
        let json = #"{"createdAt":"2026-10-01T09:00:00Z","folder":"/Users/sam/Trips","id":"old1","messages":[{"blocks":[],"createdAt":"2026-10-01T09:00:00Z","id":"m1","role":"user","text":"Plan Goa"}],"pinned":false,"title":"Goa","updatedAt":"2026-10-01T09:05:00Z"}"#
        let old = try JSONFile.decoder.decode(Chat.self, from: Data(json.utf8))
        #expect(old.groupId == nil)
        #expect(old.folder == "/Users/sam/Trips")

        var filed = old
        filed.groupId = "g1"
        let back = try JSONFile.decoder.decode(Chat.self, from: JSONFile.encoder.encode(filed))
        #expect(back.groupId == "g1")
        #expect(back.folder == "/Users/sam/Trips")

        // A folder needs an id and a name; the other fields fall back to defaults.
        let g = try JSONFile.decoder.decode(ChatGroup.self, from: Data(#"{"id":"g1","name":"  Work  ","collapsed":"yes"}"#.utf8))
        #expect(g.name == "Work")
        #expect(!g.collapsed)
        #expect(throws: DecodingError.self) { try JSONFile.decoder.decode(ChatGroup.self, from: Data(#"{"id":"g1","name":"  "}"#.utf8)) }
        #expect(throws: DecodingError.self) { try JSONFile.decoder.decode(ChatGroup.self, from: Data(#"{"id":"../x","name":"Work"}"#.utf8)) }
    }

    @Test func searchFindsChatsInFolders() throws {
        let (store, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        store.save(chat("a1", "Trip ideas", text: "Book a beach shack in Goa"))
        store.save(chat("b1", "Taxes", text: "File my taxes"))
        let trips = try #require(store.createGroup("Trips"))
        store.move("a1", to: trips.id)

        #expect(store.search("goa").map(\.id) == ["a1"])
        #expect(store.search("trip ideas").map(\.id) == ["a1"])
        #expect(store.search("goa").first?.groupId == trips.id)
    }

    @MainActor @Test func folderChatsLeaveTheDateList() {
        let now = Date()
        var a = chat("a1", "Older", updated: now.addingTimeInterval(-300))
        var b = chat("b1", "Newest", updated: now)
        var c = chat("c1", "Pinned", updated: now.addingTimeInterval(-600))
        let d = chat("d1", "Loose", updated: now.addingTimeInterval(-60))
        var e = chat("e1", "Folder was deleted", updated: now.addingTimeInterval(-30))
        a.groupId = "g1"; b.groupId = "g1"; c.groupId = "g1"; c.pinned = true
        e.groupId = "gone"
        // Newest first, as ChatStore.summaries returns them.
        let split = SidebarView.split([b, e, d, a, c].map(ChatSummary.init), groups: [ChatGroup(id: "g1", name: "Trips", createdAt: now)])
        #expect(split.inFolder["g1"]?.map(\.id) == ["c1", "b1", "a1"])
        #expect(split.rest.map(\.id) == ["e1", "d1"])
    }

    /// The actions the sidebar calls. Uses the test scheme's scratch data folder, never a real profile.
    @MainActor @Test func sidebarActions() throws {
        try #require(ProcessInfo.processInfo.environment["TARN_DATA_DIR"] != nil)
        let model = AppModel()
        let id = "folder-test-\(UUID().uuidString.prefix(8))"
        model.store.save(chat(id, "Draft"))
        defer { model.deleteChat(id) }
        model.openChat(id)

        // "Move to folder ▸ New folder…" with an empty name.
        model.createGroup("  ", moving: id)
        let group = try #require(model.groups.first { $0.id == model.store.chats[id]?.groupId })
        #expect(group.name == "New folder")
        #expect(model.current?.groupId == group.id)
        #expect(model.summaries.first { $0.id == id }?.groupId == group.id)

        // Drops: a stray string (say, a file path) is refused; a chat already there doesn't count.
        #expect(!model.moveChats(["/Users/sam/notes.txt"], to: group.id))
        #expect(!model.moveChats([id], to: group.id))
        model.moveChat(id, to: nil)
        #expect(model.moveChats([id], to: group.id))

        model.deleteGroup(group.id)
        #expect(!model.groups.contains { $0.id == group.id })
        #expect(model.store.chats[id] != nil)
        #expect(model.current?.groupId == nil)
        #expect(model.summaries.first { $0.id == id }?.groupId == nil)
    }

    @Test func backupKeepsFolders() throws {
        let (store, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("b.zip")
        let t = Date(timeIntervalSince1970: 1_790_000_000) // whole seconds survive ISO 8601
        let work = ChatGroup(id: "g1", name: "Work", createdAt: t, collapsed: true)
        let trips = ChatGroup(id: "g2", name: "Trips", createdAt: t)
        var filed = chat("a1", "Q3 plan")
        filed.groupId = "g1"
        try Backup.export(to: zip, chats: [filed, chat("b1", "Loose")], groups: [trips, work], settings: AppSettings(), connectors: [])

        let back = try Backup.read(zip)
        #expect(back.groups == [trips, work])
        #expect(back.chats.first { $0.id == "a1" }?.groupId == "g1")
        #expect(back.chats.first { $0.id == "b1" }?.groupId == nil)

        // Restoring on a new Mac brings back the folders with their chats in them.
        for c in back.chats { store.save(c) }
        store.importGroups(back.groups, replace: true)
        let next = reopen(root)
        #expect(next.groups == [trips, work])
        #expect(next.chats["a1"]?.groupId == "g1")

        // Merging into a Mac that already has folders leaves those as they are.
        let (mine, mineRoot) = try scratch()
        defer { try? FileManager.default.removeItem(at: mineRoot) }
        let office = try #require(mine.createGroup("Office"))
        mine.importGroups([ChatGroup(id: office.id, name: "Renamed elsewhere", createdAt: t), work, work], replace: false)
        #expect(reopen(mineRoot).groups.map(\.name) == ["Office", "Work"])

        // Backups from before folders have no groups.json.
        let oldZip = root.appendingPathComponent("old.zip")
        let archive = try Archive(url: oldZip, accessMode: .create)
        let manifest = Data(#"{"format":"tarn-backup","version":1}"#.utf8)
        let oldChat = try JSONFile.encoder.encode(chat("old1", "Old"))
        for (path, d) in [("manifest.json", manifest), ("chats/old1.json", oldChat)] {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(d.count)) { pos, size in d.subdata(in: Int(pos)..<Int(pos) + size) }
        }
        let old = try Backup.read(oldZip)
        #expect(old.groups.isEmpty)
        #expect(old.chats.map(\.id) == ["old1"])
    }
}

@Suite("Documents")
struct DocumentTests {
    func scratchFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tarn-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func wordRoundTrip() throws {
        let dir = try scratchFolder()
        let url = dir.appendingPathComponent("summary.docx")
        try Documents.write("# Q4 launch\n- **Owner:** Priya\n- [ ] Fix checkout\n1. Ship on Friday", to: url)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: Data("PK".utf8)))   // a real .docx is a zip package
        let text = try #require(try Documents.text(url, data))
        #expect(text.contains("Q4 launch") && text.contains("Owner: Priya") && text.contains("Fix checkout") && text.contains("Ship on Friday"))
        #expect(!text.contains("**") && !text.contains("# "))
    }

    @Test func markdownTablesBecomeWordTables() throws {
        let dir = try scratchFolder()
        let url = dir.appendingPathComponent("plan.docx")
        try Documents.write("## Action items\n\n| Owner | Task |\n|-------|------|\n| Rahul | Fix *Android* checkout |\n\n---\nNext sync Tuesday", to: url)
        let text = try #require(try Documents.text(url, try Data(contentsOf: url)))
        #expect(text.contains("Owner") && text.contains("Rahul") && text.contains("Fix Android checkout") && text.contains("Next sync Tuesday"))
        #expect(!text.contains("|") && !text.contains("---") && !text.contains("*"))
    }

    @Test func readFileReadsPDFsAndWord() async throws {
        let dir = try scratchFolder()
        // A one-page PDF with real text.
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Security deposit: six months of rent", attributes: [.font: NSFont.systemFont(ofSize: 14)]).draw(at: CGPoint(x: 72, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        try (pdf as Data).write(to: dir.appendingPathComponent("lease.pdf"))
        try Documents.write("Notes from **today**", to: dir.appendingPathComponent("notes.docx"))

        var chat = Chat(id: "d1", title: "Docs", createdAt: Date(), updatedAt: Date())
        chat.folder = dir.path
        let ctxTool = ToolContext(chat: chat)
        let lease = try await ReadFileTool().run(["path": "lease.pdf"], ctxTool)
        #expect(lease.contains("Security deposit: six months of rent"))
        let notes = try await ReadFileTool().run(["path": "notes.docx"], ctxTool)
        #expect(notes.contains("Notes from today"))
        // Word files are never edited in place (that would drop their formatting).
        await #expect(throws: ToolFailure.self) {
            _ = try await EditFileTool().run(["path": "notes.docx", "old_text": "today", "new_text": "Monday"], ctxTool)
        }
        // write_file to .docx makes a Word document.
        _ = try await WriteFileTool().run(["path": "clean.docx", "content": "# Clean\n- one"], ctxTool)
        let clean = try Data(contentsOf: dir.appendingPathComponent("clean.docx"))
        #expect(clean.starts(with: Data("PK".utf8)))
    }

    @Test func attachingAWordDocument() throws {
        let dir = try scratchFolder()
        let url = dir.appendingPathComponent("cover-letter.docx")
        try Documents.write("Dear hiring team,\nI build **fintech** products.", to: url)
        let a = try Attachments.read(url)
        #expect(a.kind == .text)
        #expect(a.text.contains("I build fintech products."))
    }
}
