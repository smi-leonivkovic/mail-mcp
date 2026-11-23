import Foundation

// Newsletter discovery and unsubscribing.
//
// The index has no headers, so candidates come from the index (grouped by sender) and the
// headers of each sender's latest message come from Mail via `all headers of m`.
// Unsubscribe options are read from List-Unsubscribe / List-Unsubscribe-Post (RFC 2369 / 8058);
// without them, the raw source is scanned for an unsubscribe link in the HTML.

// MARK: - Model

struct UnsubscribeInfo {
    var https: [String] = []
    var mailto: [String] = []
    var oneClick = false          // List-Unsubscribe-Post: List-Unsubscribe=One-Click
    var bodyLinks: [String] = []  // fallback: links found in the message body
    var from = ""
    var listId = ""

    var hasHeader: Bool { !https.isEmpty || !mailto.isEmpty }

    /// The method mail_unsubscribe would use.
    var method: String {
        if oneClick, !https.isEmpty { return "one-click" }
        if !mailto.isEmpty { return "mailto" }
        if !https.isEmpty { return "https (manual)" }
        if !bodyLinks.isEmpty { return "body link (manual)" }
        return "none"
    }
}

// MARK: - Header parsing

/// Unfold RFC 5322 headers into (lowercased name, value) pairs. Stops at the first blank line.
func parseHeaders(_ raw: String) -> [(String, String)] {
    var out: [(String, String)] = []
    for line in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
        if line.isEmpty { if !out.isEmpty { break } else { continue } }
        if let first = line.first, first == " " || first == "\t", !out.isEmpty {
            out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        out.append((name, value))
    }
    return out
}

func unsubscribeInfo(fromHeaders raw: String) -> UnsubscribeInfo {
    var info = UnsubscribeInfo()
    for (name, value) in parseHeaders(raw) {
        switch name {
        case "list-unsubscribe":
            // "<https://…>, <mailto:…>" — each target in angle brackets.
            var rest = Substring(value)
            while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
                let target = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let lower = target.lowercased()
                if lower.hasPrefix("https://") { info.https.append(target) }
                else if lower.hasPrefix("mailto:") { info.mailto.append(target) }
                rest = rest[rest.index(after: close)...]
            }
        case "list-unsubscribe-post":
            if value.lowercased().replacingOccurrences(of: " ", with: "").contains("list-unsubscribe=one-click") {
                info.oneClick = true
            }
        case "from":
            if info.from.isEmpty { info.from = value }
        case "list-id":
            if info.listId.isEmpty { info.listId = value }
        default:
            break
        }
    }
    return info
}

/// Bare email address from a From header value ("Name <a@b.c>" → "a@b.c").
func bareAddress(_ from: String) -> String {
    if let open = from.lastIndex(of: "<"), let close = from[open...].firstIndex(of: ">") {
        return from[from.index(after: open)..<close].trimmingCharacters(in: .whitespaces).lowercased()
    }
    return from.trimmingCharacters(in: .whitespaces).lowercased()
}

// MARK: - Body link fallback

// Stems, so "Newsletterabmeldung", "abbestellt", "unsubscription" etc. match too.
private let unsubscribeWords = [
    "unsubscri", "abmeld", "abbestell", "austragen", "opt-out", "optout", "opt out",
    "désinscri", "desinscri", "darse de baja", "disiscriviti", "afmelden", "uitschrijven",
    "keine e-mails mehr", "keine emails mehr", "keine newsletter mehr",
]

private func decodeQuotedPrintable(_ s: String) -> String {
    let unfolded = s.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
    var bytes: [UInt8] = []
    var it = Array(unfolded.utf8)[...]
    while let c = it.first {
        it = it.dropFirst()
        if c == UInt8(ascii: "="), it.count >= 2,
           let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) {
            bytes.append(v)
            it = it.dropFirst(2)
        } else {
            bytes.append(c)
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Decode base64 MIME parts (text only) so their links can be scanned too.
private func decodedBase64Parts(_ source: String) -> [String] {
    var out: [String] = []
    let text = source.replacingOccurrences(of: "\r\n", with: "\n")
    var search = text.startIndex..<text.endIndex
    while let r = text.range(of: "content-transfer-encoding: base64", options: .caseInsensitive, range: search) {
        search = r.upperBound..<text.endIndex
        // Only text parts: look back a little for the part's Content-Type.
        let lookStart: String.Index = text.index(r.lowerBound, offsetBy: -400, limitedBy: text.startIndex) ?? text.startIndex
        let lookBack = String(text[lookStart..<r.lowerBound])
        let opts: String.CompareOptions = [.caseInsensitive, .backwards]
        guard let typeRange = lookBack.range(of: "content-type:", options: opts),
              lookBack[typeRange.upperBound...].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("text/") else { continue }
        guard let bodyStart = text.range(of: "\n\n", range: r.upperBound..<text.endIndex) else { break }
        var lines: [Substring] = []
        for line in text[bodyStart.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("--") { break }
            lines.append(line)
        }
        if let data = Data(base64Encoded: lines.joined(), options: .ignoreUnknownCharacters) {
            out.append(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "")
        }
    }
    return out
}

private let anchorRegex = try! NSRegularExpression(
    pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators])
private let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
/// Plain-text parts: "Newsletterabmeldung [https://…]" or "Abmelden: <https://…>".
private let plainLinkRegex = try! NSRegularExpression(
    pattern: #"([^\n\[\]<>]{0,80})[\[<](https?://[^\]>\s]+)[\]>]"#, options: [.caseInsensitive])

/// Links in the message source whose anchor text or URL looks like an unsubscribe link.
func unsubscribeLinks(inSource source: String) -> [String] {
    let corpus = [decodeQuotedPrintable(source)] + decodedBase64Parts(source)
    var found: [String] = []
    for text in corpus {
        let ns = text as NSString
        for m in anchorRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.lowercased().hasPrefix("http") else { continue }
            let inner = ns.substring(with: m.range(at: 2))
            let label = tagRegex.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length), withTemplate: " ")
            // Text right before the link counts too ("Keine E-Mails mehr? Hier klicken").
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 120), length: min(120, m.range.location)))
            let haystack = (label + " " + url + " " + tagRegex.stringByReplacingMatches(in: before, range: NSRange(location: 0, length: (before as NSString).length), withTemplate: " ")).lowercased()
            if unsubscribeWords.contains(where: { haystack.contains($0) }), !found.contains(url) {
                found.append(url)
            }
        }
        for m in plainLinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range(at: 2))
            let haystack = (ns.substring(with: m.range(at: 1)) + " " + url).lowercased()
            if unsubscribeWords.contains(where: { haystack.contains($0) }), !found.contains(url) {
                found.append(url)
            }
        }
    }
    return found
}

// MARK: - Fetching headers / source from Mail

struct MessageRefSpec {
    let id: Int
    let location: Location
}

/// `all headers` (or `source`) of several messages in one AppleScript call. Missing messages map to "".
func fetchMailText(_ specs: [MessageRefSpec], property: String) throws -> [Int: String] {
    var out: [Int: String] = [:]
    for chunk in stride(from: 0, to: specs.count, by: 25).map({ Array(specs[$0..<min($0 + 25, specs.count)]) }) {
        let body = chunk.map { s in
            """
            try
                set m to \(messageRef(id: s.id, account: s.location.account, mailbox: s.location.mailbox))
                set out to out & "\(s.id)" & FS & (\(property) of m) & RS
            on error
                set out to out & "\(s.id)" & FS & "" & RS
            end try
            """
        }.joined(separator: "\n")
        let raw = try runMail("""
        set FS to character id 31
        set RS to character id 30
        set out to ""
        \(body)
        return out
        """)
        for r in raw.components(separatedBy: RS) where !r.isEmpty {
            guard let sep = r.firstIndex(of: Character(FS)), let id = Int(r[..<sep]) else { continue }
            out[id] = String(r[r.index(after: sep)...])
        }
    }
    return out
}

/// Unsubscribe info for messages; scans the body when there is no header (or always, if scanBody).
func unsubscribeInfos(_ specs: [MessageRefSpec], scanBody: Bool) throws -> [Int: UnsubscribeInfo] {
    var infos: [Int: UnsubscribeInfo] = [:]
    for (id, headers) in try fetchMailText(specs, property: "all headers") {
        infos[id] = unsubscribeInfo(fromHeaders: headers)
    }
    let needBody = specs.filter { scanBody || !(infos[$0.id]?.hasHeader ?? false) }
    if !needBody.isEmpty {
        for (id, source) in try fetchMailText(needBody, property: "source") where !source.isEmpty {
            infos[id, default: UnsubscribeInfo()].bodyLinks = unsubscribeLinks(inSource: source)
        }
    }
    return infos
}

// MARK: - Index: senders grouped

struct SenderGroup {
    let address: String
    let name: String
    let count: Int
    let lastDate: Int
    let latestId: Int
    let mailboxId: Int
}

extension MailIndex {
    /// Senders in the given mailboxes, most messages first, with each sender's latest message.
    func senderGroups(mailboxIds: [Int], since: Date?, minCount: Int, limit: Int) throws -> [SenderGroup] {
        guard !mailboxIds.isEmpty else { return [] }
        var conds = ["m.deleted = 0", "m.mailbox IN (\(mailboxIds.map(String.init).joined(separator: ",")))", "a.address <> ''"]
        var binds: [Any] = []
        if let since { conds.append("m.date_received >= ?"); binds.append(Int(since.timeIntervalSince1970)) }
        binds += [minCount, limit]
        // SQLite: bare columns next to MAX() come from the row holding the max.
        let sql = """
        SELECT lower(a.address), IFNULL(a.comment,''), COUNT(DISTINCT IFNULL(m.global_message_id, m.ROWID)),
               MAX(m.date_received), m.ROWID, m.mailbox
        FROM messages m
        JOIN addresses a ON a.ROWID = m.sender
        WHERE \(conds.joined(separator: " AND "))
        GROUP BY lower(a.address)
        HAVING COUNT(DISTINCT IFNULL(m.global_message_id, m.ROWID)) >= ?
        ORDER BY 3 DESC, 4 DESC
        LIMIT ?
        """
        return try rows(sql, binds).map { r in
            SenderGroup(address: r[0], name: r[1], count: Int(r[2]) ?? 0, lastDate: Int(r[3]) ?? 0,
                        latestId: Int(r[4]) ?? 0, mailboxId: Int(r[5]) ?? 0)
        }
    }
}

// MARK: - Tools

func listNewsletters(_ a: [String: Any]) throws -> String {
    guard let idx = MailIndex.shared else {
        throw ToolError("mail_list_newsletters needs Mail's index (grant Full Disk Access to the host app).")
    }
    let limit = max(1, min(a.int("limit", 100), 500))
    let minCount = max(1, a.int("minCount", 1))
    let since = a.str("since").isEmpty ? nil : try parseDay(a.str("since"))
    let includeWithout = a.bool("includeWithoutHeader", false)
    let t0 = Date()

    let boxes = try scopeMailboxes(idx, account: a.str("account"), mailbox: a.str("mailbox"), includeTrash: false)
    let own = Set(try mailAccounts().flatMap(\.emails).map { $0.lowercased() })
    // Over-fetch: own addresses and senders without a header get dropped below.
    let groups = try idx.senderGroups(mailboxIds: Array(boxes.keys), since: since, minCount: minCount, limit: limit * 3)
        .filter { !own.contains($0.address) }
    let specs = groups.compactMap { g -> MessageRefSpec? in
        guard let box = boxes[g.mailboxId] else { return nil }
        return MessageRefSpec(id: g.latestId, location: Location(account: accountName(forId: box.accountId), mailbox: box.path))
    }
    let headers = try fetchMailText(specs, property: "all headers")

    var with: [String] = []
    var without: [String] = []
    var total = 0
    for g in groups {
        let info = unsubscribeInfo(fromHeaders: headers[g.latestId] ?? "")
        let who = g.name.isEmpty ? g.address : "\(g.name) <\(g.address)>"
        let line = "• \(who) — \(g.count) msg, last \(displayDate(g.lastDate)), messageId \(g.latestId)"
        if info.hasHeader {
            guard with.count < limit else { continue }
            total += g.count
            with.append(line + "\n  method: \(info.method)\(info.listId.isEmpty ? "" : "  list: \(info.listId)")")
        } else if includeWithout, without.count < limit {
            without.append(line)
        }
    }
    let scope = a.str("account").isEmpty ? "all enabled accounts" : a.str("account")
    var out = ["Newsletters in \(scope) — \(with.count) sender(s) with List-Unsubscribe, \(total) messages (\(Int(Date().timeIntervalSince(t0) * 1000)) ms; checked the latest message of \(groups.count) senders):", ""]
    out += with.isEmpty ? ["(none found)"] : with
    if includeWithout {
        out += ["", "Senders without a List-Unsubscribe header (\(without.count)) — use mail_get_unsubscribe to scan their body for a link, or treat as spam:", ""]
        out += without
    }
    out += ["", "Next: mail_unsubscribe with the messageIds (dryRun is on by default)."]
    return out.joined(separator: "\n")
}

func specs(for ids: [Int], _ a: [String: Any]) throws -> [MessageRefSpec] {
    try ids.map { MessageRefSpec(id: $0, location: try locate($0, a)) }
}

func getUnsubscribe(_ a: [String: Any]) throws -> String {
    let ids = a.messageIds()
    guard !ids.isEmpty else { throw ToolError("Missing required argument 'messageId' or 'messageIds'") }
    let infos = try unsubscribeInfos(try specs(for: ids, a), scanBody: a.bool("scanBody", false))
    var out: [String] = []
    for id in ids {
        guard let info = infos[id] else { out += ["• messageId \(id): message not found", ""]; continue }
        out.append("• messageId \(id) — \(info.from.isEmpty ? "?" : info.from)")
        out.append("  method: \(info.method)")
        if !info.listId.isEmpty { out.append("  List-Id: \(info.listId)") }
        info.https.forEach { out.append("  https: \($0)\(info.oneClick ? "  (one-click)" : "")") }
        info.mailto.forEach { out.append("  mailto: \($0)") }
        info.bodyLinks.forEach { out.append("  body link: \($0)") }
        out.append("")
    }
    return out.joined(separator: "\n")
}

/// RFC 8058 one-click: POST "List-Unsubscribe=One-Click" to the https target.
func oneClickPost(_ urlString: String) -> (ok: Bool, detail: String) {
    guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return (false, "invalid URL") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("mail-mcp", forHTTPHeaderField: "User-Agent")
    req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
    let done = DispatchSemaphore(value: 0)
    var result: (Bool, String) = (false, "no response")
    URLSession.shared.dataTask(with: req) { _, resp, err in
        if let err { result = (false, err.localizedDescription) }
        else if let http = resp as? HTTPURLResponse { result = ((200..<300).contains(http.statusCode), "HTTP \(http.statusCode)") }
        done.signal()
    }.resume()
    done.wait()
    return result
}

/// "mailto:a@b.c?subject=x&body=y" → (address, subject, body)
func parseMailto(_ s: String) -> (to: String, subject: String, body: String)? {
    guard let c = URLComponents(string: s), c.scheme?.lowercased() == "mailto" else { return nil }
    let to = c.path.removingPercentEncoding ?? c.path
    guard to.contains("@") else { return nil }
    let item = { (n: String) in c.queryItems?.first { $0.name.lowercased() == n }?.value ?? "" }
    return (to, item("subject").isEmpty ? "unsubscribe" : item("subject"), item("body"))
}

func unsubscribe(_ a: [String: Any]) throws -> String {
    let ids = a.messageIds()
    guard !ids.isEmpty else { throw ToolError("Missing required argument 'messageId' or 'messageIds'") }
    let dryRun = a.bool("dryRun", true)
    let sendMailto = a.bool("sendMailto", false)
    let allSpecs = try specs(for: ids, a)
    let infos = try unsubscribeInfos(allSpecs, scanBody: false)

    var seen = Set<String>()
    var done: [String] = [], drafts: [String] = [], manual: [String] = [], failed: [String] = [], skipped: [String] = []
    for spec in allSpecs {
        guard let info = infos[spec.id] else { failed.append("messageId \(spec.id): message not found"); continue }
        let sender = bareAddress(info.from)
        let key = info.listId.isEmpty ? sender : info.listId.lowercased()
        guard seen.insert(key).inserted else { skipped.append("messageId \(spec.id) (\(sender)): same sender as an earlier id"); continue }
        let who = "\(info.from.isEmpty ? "messageId \(spec.id)" : info.from) [\(spec.id)]"

        if info.oneClick, let target = info.https.first {
            if dryRun { done.append("\(who): would POST one-click to \(target)"); continue }
            let r = oneClickPost(target)
            if r.ok { done.append("\(who): unsubscribed (one-click, \(r.detail))") }
            else if let m = info.mailto.first.flatMap(parseMailto) {
                // One-click failed; fall back to the mailto target.
                _ = try composeMessage(["to": [m.to], "subject": m.subject, "body": m.body, "from": spec.location.account,
                                        "signature": "none", "send": sendMailto])
                let note = "\(who): one-click failed (\(r.detail)); \(sendMailto ? "sent" : "drafted") mail to \(m.to)"
                if sendMailto { done.append(note) } else { drafts.append(note) }
            } else {
                failed.append("\(who): one-click failed (\(r.detail)) — open manually: \(target)")
            }
            continue
        }
        if let m = info.mailto.first.flatMap(parseMailto) {
            let note: String
            if dryRun {
                note = "\(who): would \(sendMailto ? "send" : "draft") “\(m.subject)” to \(m.to) from \(spec.location.account)"
            } else {
                _ = try composeMessage(["to": [m.to], "subject": m.subject, "body": m.body, "from": spec.location.account,
                                        "signature": "none", "send": sendMailto])
                note = "\(who): \(sendMailto ? "sent" : "drafted") “\(m.subject)” to \(m.to)"
            }
            if sendMailto { done.append(note) } else { drafts.append(note) }
            continue
        }
        if let target = info.https.first { manual.append("\(who): no one-click support — open \(target)"); continue }
        if let link = info.bodyLinks.first { manual.append("\(who): no List-Unsubscribe header — body link \(link)"); continue }
        failed.append("\(who): no unsubscribe option found (spam? consider marking as junk)")
    }

    var out = [dryRun ? "Unsubscribe plan (dry run — nothing sent; pass dryRun=false to execute):" : "Unsubscribe results:", ""]
    func section(_ title: String, _ items: [String]) {
        guard !items.isEmpty else { return }
        out.append("\(title) (\(items.count)):")
        out += items.map { "  • \($0)" }
        out.append("")
    }
    section(dryRun ? "One-click" : "Done", done)
    section(dryRun ? "Mailto drafts" : "Drafts opened in Mail (review and send)", drafts)
    section("Manual — open the link yourself", manual)
    section("Failed / nothing found", failed)
    section("Skipped (duplicate sender)", skipped)
    return out.joined(separator: "\n")
}
