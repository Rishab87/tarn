import Foundation

private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

enum NetGuard {
    /// True for loopback, private, link-local, CGNAT, multicast and other non-public addresses.
    static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            return a == 0 || a == 10 || a == 127 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 198 && (b == 18 || b == 19)) || a >= 224
        }
        let v6 = ip.lowercased()
        if v6 == "::" || v6 == "::1" { return true }
        if v6.hasPrefix("::ffff:") { return isPrivate(String(v6.dropFirst(7))) }
        return ["fc", "fd", "fe8", "fe9", "fea", "feb", "ff"].contains { v6.hasPrefix($0) }
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let a = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = a.pointee.ai_next
        }
        return out
    }

    /// Pages the model reads can contain instructions. To stop a page from steering the model
    /// into your router or other local services, only public addresses are allowed.
    static func checkPublic(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host() else {
            throw ToolFailure("That isn’t a valid web address.")
        }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".localhost") {
            throw ToolFailure("Tarn doesn’t open addresses on your local network.")
        }
        let addrs = resolve(h)
        if addrs.isEmpty { throw ToolFailure("Couldn’t find the website \(h).") }
        if addrs.contains(where: isPrivate) { throw ToolFailure("Tarn doesn’t open addresses on your local network.") }
        return url
    }
}

/// Stops URLSession from following redirects so each hop can be checked.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum HTMLText {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•", "deg": "°",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacing(/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);/) { m in
            let e = String(m.1)
            if e.hasPrefix("#x") || e.hasPrefix("#X"), let v = UInt32(e.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { return String(Character(u)) }
            if e.hasPrefix("#"), let v = UInt32(e.dropFirst()), let u = Unicode.Scalar(v) { return String(Character(u)) }
            return named[e.lowercased()] ?? String(m.0)
        }
    }

    /// Readable text from an HTML page: drops scripts, navigation and markup; keeps headings and lists.
    static func toText(_ html: String) -> String {
        var body = html
        let title = html.firstMatch(of: /(?is)<title[^>]*>(.*?)<\/title>/).map { decodeEntities(String($0.1)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let main = html.firstMatch(of: /(?is)<(main|article)[^>]*>(.*?)<\/\1>/), main.2.count > 500 { body = String(main.2) }
        body = body
            .replacing(/(?is)<(script|style|noscript|svg|template|iframe|head)[^>]*>.*?<\/\1>/, with: " ")
            .replacing(/(?is)<(nav|footer|aside|form)[^>]*>.*?<\/\1>/, with: " ")
            .replacing(/(?s)<!--.*?-->/, with: " ")
            .replacing(/(?i)<h([1-6])[^>]*>/) { m in "\n\n" + String(repeating: "#", count: Int(m.1) ?? 1) + " " }
            .replacing(/(?i)<\/(p|div|section|h[1-6]|li|tr|blockquote|pre|table|ul|ol)>/, with: "\n")
            .replacing(/(?i)<(br|hr)\s*\/?>/, with: "\n")
            .replacing(/(?i)<li[^>]*>/, with: "\n• ")
            .replacing(/(?i)<t[dh][^>]*>/, with: " | ")
            .replacing(/<[^>]+>/, with: " ")
        let text = decodeEntities(body)
            .replacing(/[ \t\u{000C}\u{000B}\u{00A0}]+/, with: " ")
            .replacing(#/ *\n */#, with: "\n")
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty { return "\(title)\n\n\(text)" }
        return text
    }
}

struct SearchResult: Equatable {
    let title: String
    let url: String
    let snippet: String
}

enum DuckDuckGo {
    static func parse(_ html: String) -> [SearchResult] {
        var out: [SearchResult] = []
        let strip = { (s: Substring?) -> String in
            HTMLText.decodeEntities((s.map(String.init) ?? "").replacing(/<[^>]+>/, with: "")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        for m in html.matches(of: /(?s)<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>(?:.*?<a[^>]*class="result__snippet"[^>]*>(.*?)<\/a>)?/) {
            var href = HTMLText.decodeEntities(String(m.1))
            if let w = href.firstMatch(of: /[?&]uddg=([^&]+)/), let d = String(w.1).removingPercentEncoding { href = d }
            if href.hasPrefix("//") { href = "https:" + href }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js") else { continue }
            out.append(SearchResult(title: strip(m.2), url: href, snippet: strip(m.3)))
            if out.count >= 8 { break }
        }
        return out
    }
}

struct WebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the web for current information: news, prices, opening hours, recent events, facts you are unsure of. Returns titles, links and snippets. Open a result with fetch_page for details."
    var parameters: [String: Any] { schema(["query": ["type": "string", "description": "What to search for, in plain words."]], required: ["query"]) }

    func label(_ args: [String: Any]) -> String { "Searched the web for “\((args["query"] as? String ?? "").prefix(80))”" }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        let query = String(try args.string("query").prefix(300))
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        guard let (data, res) = try? await URLSession.shared.data(for: req) else { throw ToolFailure("Web search is unreachable. Check the internet connection.") }
        guard (res as? HTTPURLResponse)?.statusCode == 200 else { throw ToolFailure("Web search is unavailable right now. Try again in a minute.") }
        let results = DuckDuckGo.parse(String(decoding: data, as: UTF8.self))
        if results.isEmpty { return "No results found." }
        return results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n\($0.element.url)\n\($0.element.snippet)" }.joined(separator: "\n\n")
    }
}

struct FetchPageTool: Tool {
    let name = "fetch_page"
    let description = "Open a web page and read its text. Use it for links the user gives you or results from web_search."
    var parameters: [String: Any] { schema(["url": ["type": "string", "description": "Full address starting with http:// or https://"]], required: ["url"]) }

    func label(_ args: [String: Any]) -> String {
        if let s = args["url"] as? String, let host = URL(string: s)?.host() { return "Read \(host.replacingOccurrences(of: "www.", with: ""))" }
        return "Read a web page"
    }

    func run(_ args: [String: Any], _ ctx: ToolContext) async throws -> String {
        var url = try NetGuard.checkPublic(try args.string("url"))
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for _ in 0..<6 {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
            let (bytes, res): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, res) = try await session.bytes(for: req)
            } catch {
                throw ToolFailure("Couldn’t open that page. It may be down or blocking automated visits.")
            }
            let http = res as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (300..<400).contains(status), let loc = http?.value(forHTTPHeaderField: "Location"), let next = URL(string: loc, relativeTo: url) {
                url = try NetGuard.checkPublic(next.absoluteString)
                continue
            }
            guard (200..<300).contains(status) else { throw ToolFailure("The page answered with an error (\(status)).") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 3_000_000 { break }
            }
            let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let body = String(decoding: data, as: UTF8.self)
            if type.contains("html") || type.contains("xml") || body.hasPrefix("<") { return clip(HTMLText.toText(body), 14000) }
            if type.contains("text") || type.contains("json") || type.contains("csv") { return clip(body, 14000) }
            throw ToolFailure("That address isn’t a readable page (\(type.isEmpty ? "unknown type" : type)).")
        }
        throw ToolFailure("That page redirected too many times.")
    }
}
