import Foundation

// MARK: - Shared helpers

/// The Mail index, unless unavailable or the caller passed useIndex=false (force the AppleScript lookup).
func indexIfEnabled(_ a: [String: Any]) -> MailIndex? {
    a.bool("useIndex", true) ? MailIndex.shared : nil
}

/// Run the fast index path; on any index error, log it and return nil so the caller uses AppleScript.
func viaIndex(_ a: [String: Any], _ body: (MailIndex) throws -> String) -> String? {
    guard let idx = indexIfEnabled(a) else { return nil }
    do { return try body(idx) }
    catch let e as ToolError where e.description.hasPrefix("Account '") { return "Error: \(e)" }
    catch { log("Mail index failed, using AppleScript fallback: \(error)"); return nil }
}

func accountName(forId id: String) -> String {
    if let a = (try? mailAccounts())?.first(where: { $0.id == id }) { return a.name }
    if let a = (try? mailAccounts(refresh: true))?.first(where: { $0.id == id }) { return a.name }
    return "On My Mac"
}

/// Where a message lives, as Mail's AppleScript addresses it.
struct Location: Hashable {
    let account: String
    let mailbox: String
}

func locate(_ id: Int, _ a: [String: Any]) throws -> Location {
    if let idx = indexIfEnabled(a) {
        do {
            if let box = try idx.mailbox(ofMessage: id) {
                return Location(account: accountName(forId: box.accountId), mailbox: box.path)
            }
        } catch { log("index lookup failed, falling back: \(error)") }
    }
    let acct = a.str("account")
    guard !acct.isEmpty else {
        throw ToolError("Pass 'account' (and 'mailbox' if not INBOX) — the Mail index isn't available to look up message \(id).")
    }
    return Location(account: try requireAccount(acct).name, mailbox: a.str("mailbox", "INBOX"))
}

/// Mailboxes in scope for an index query.
func scopeMailboxes(_ idx: MailIndex, account: String, mailbox: String, includeTrash: Bool) throws -> [Int: MailIndex.Mailbox] {
    let accounts = try mailAccounts()
    let wanted = account.isEmpty ? nil : try requireAccount(account)
    let enabledIds = Set(accounts.filter(\.enabled).map(\.id))
    let knownIds = Set(accounts.map(\.id))
    let mbKey = mailbox.lowercased()
    var out: [Int: MailIndex.Mailbox] = [:]
    for box in try idx.mailboxes() {
        if let wanted {
            guard box.accountId == wanted.id else { continue }
        } else if knownIds.contains(box.accountId) && !enabledIds.contains(box.accountId) {
            continue  // disabled account
        }
        if !mbKey.isEmpty {
            guard box.path.lowercased() == mbKey || box.base == mbKey else { continue }
        } else if !includeTrash && trashLikeMailboxes.contains(box.base) {
            continue
        }
        out[box.rowid] = box
    }
    return out
}

func dedupe(_ hits: [MailIndex.Hit], _ boxes: [Int: MailIndex.Mailbox]) -> [MailIndex.Hit] {
    func isAggregate(_ h: MailIndex.Hit) -> Bool { aggregateMailboxes.contains(boxes[h.mailboxId]?.base ?? "") }
    var position: [String: Int] = [:]
    var result: [MailIndex.Hit] = []
    for h in hits {
        if let i = position[h.globalId] {
            if isAggregate(result[i]) && !isAggregate(h) { result[i] = h }
        } else {
            position[h.globalId] = result.count
            result.append(h)
        }
    }
    return result
}

func formatHits(_ hits: [MailIndex.Hit], _ boxes: [Int: MailIndex.Mailbox], header: String, elapsed: TimeInterval) -> String {
    if hits.isEmpty { return "\(header): no messages found." }
    var lines = ["\(header) — \(hits.count) message(s) (\(Int(elapsed * 1000)) ms, Mail index):", ""]
    for h in hits {
        let box = boxes[h.mailboxId]
        let from = h.fromName.isEmpty ? h.fromAddress : "\(h.fromName) <\(h.fromAddress)>"
        var flags: [String] = []
        if !h.read { flags.append("● unread") }
        if h.flagged { flags.append("⚑ flagged") }
        if h.attachments > 0 { flags.append("📎 \(h.attachments)") }
        lines.append("• \(h.subject.isEmpty ? "(no subject)" : h.subject)")
        lines.append("  From: \(from)")
        lines.append("  Date: \(displayDate(h.date))\(flags.isEmpty ? "" : "  " + flags.joined(separator: " "))")
        lines.append("  messageId: \(h.id)  account: \(box.map { accountName(forId: $0.accountId) } ?? "?")  mailbox: \(box?.path ?? "?")")
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// AppleScript-fallback summary formatting (records from mcpRow).
func formatRows(_ raw: String, header: String) -> String {
    let rows = records(raw)
    if rows.isEmpty { return "\(header): no messages found." }
    var lines = ["\(header) — \(rows.count) message(s) (AppleScript fallback; grant Full Disk Access for fast search):", ""]
    for r in rows where r.count >= 8 {
        let flags = (r[6] == "false" ? "● unread " : "") + (r[7] == "true" ? "⚑ flagged" : "")
        lines.append("• \(r[5].isEmpty ? "(no subject)" : r[5])")
        lines.append("  From: \(r[4])")
        lines.append("  Date: \(r[3].replacingOccurrences(of: "T", with: " "))\(flags.isEmpty ? "" : "  \(flags)")")
        lines.append("  messageId: \(r[0])  account: \(r[1])  mailbox: \(r[2])")
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// AppleScript loop over accounts (all enabled, or one).
func overAccounts(_ account: String, _ perAccount: String) throws -> String {
    let list = account.isEmpty ? "every account whose enabled is true" : "{account \(q(try requireAccount(account).name))}"
    return """
    set out to ""
    repeat with acct in (\(list))
        set acctName to name of acct
        try
    \(perAccount)
        end try
    end repeat
    return out
    """
}

// MARK: - Accounts & mailboxes

func listAccounts(_ a: [String: Any]) throws -> String {
    let accts = try mailAccounts(refresh: true)
    var lines = ["\(accts.count) Mail account(s):", ""]
    for acct in accts {
        lines.append("• \(acct.name)\(acct.enabled ? "" : " (disabled)")")
        lines.append("  Addresses: \(acct.emails.joined(separator: ", "))")
        lines.append("  Type: \(acct.type)")
    }
    lines.append("")
    lines.append(MailIndex.shared != nil ? "Search mode: fast (Mail index)" : "Search mode: AppleScript fallback (grant Full Disk Access to the Claude app for fast search)")
    return lines.joined(separator: "\n")
}

func listMailboxes(_ a: [String: Any]) throws -> String {
    if let fast = viaIndex(a, { idx in
        let boxes = try scopeMailboxes(idx, account: a.str("account"), mailbox: "", includeTrash: true)
        var grouped: [String: [MailIndex.Mailbox]] = [:]
        for b in boxes.values { grouped[accountName(forId: b.accountId), default: []].append(b) }
        if grouped.isEmpty { return "No mailboxes found." }
        return grouped.keys.sorted().map { acct in
            "[\(acct)]\n" + grouped[acct]!.sorted { $0.path < $1.path }.map {
                "  \($0.path)  — \($0.total) messages\($0.unread > 0 ? ", \($0.unread) unread" : "")"
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }) { return fast }
    let raw = try runMail(try overAccounts(a.str("account"), """
            set FS to character id 31
            set RS to character id 30
            repeat with mbx in (every mailbox of acct)
                set unread to 0
                try
                    set unread to unread count of mbx
                end try
                set out to out & acctName & FS & (name of mbx) & FS & (unread as string) & RS
            end repeat
    """))
    var grouped: [(String, [String])] = []
    for r in records(raw) where r.count >= 3 {
        let line = "  \(r[1])\(r[2] != "0" ? "  (\(r[2]) unread)" : "")"
        if let i = grouped.firstIndex(where: { $0.0 == r[0] }) { grouped[i].1.append(line) } else { grouped.append((r[0], [line])) }
    }
    if grouped.isEmpty { return "No mailboxes found." }
    return grouped.map { "[\($0.0)]\n" + $0.1.joined(separator: "\n") }.joined(separator: "\n\n")
}

// MARK: - Listing & search

func listMessages(_ a: [String: Any]) throws -> String {
    let mailbox = a.str("mailbox", "INBOX")
    let limit = max(1, min(a.int("limit", 20), 500))
    let unreadOnly = a.bool("unreadOnly", false)
    let header = unreadOnly ? "Unread in \(mailbox)" : "Latest in \(mailbox)"

    if let fast = viaIndex(a, { idx in
        let t0 = Date()
        let boxes = try scopeMailboxes(idx, account: a.str("account"), mailbox: mailbox, includeTrash: true)
        var qy = MailIndex.Query()
        qy.mailboxIds = Array(boxes.keys)
        qy.unreadOnly = unreadOnly
        qy.limit = limit
        let hits = Array(dedupe(try idx.search(qy), boxes).prefix(limit))
        return formatHits(hits, boxes, header: header, elapsed: Date().timeIntervalSince(t0))
    }) { return fast }

    let selection = unreadOnly
        ? "set msgs to (messages of mb whose read status is false)"
        : "set n0 to count of messages of mb\nif n0 > \(limit) then set n0 to \(limit)\nif n0 = 0 then\nset msgs to {}\nelse\nset msgs to messages 1 thru n0 of mb\nend if"
    let raw = try runMail(try overAccounts(a.str("account"), """
            set mb to mailbox \(q(mailbox)) of acct
            \(selection)
            set n to count of msgs
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set out to out & my mcpRow(item i of msgs, acctName, \(q(mailbox)))
            end repeat
    """), handlers: rowHandler)
    return formatRows(raw, header: header)
}

func searchMessages(_ a: [String: Any]) throws -> String {
    let limit = max(1, min(a.int("limit", 20), 500))
    let query = a.str("query")
    let mailbox = a.str("mailbox")

    if !a.bool("searchBody", false), let fast = viaIndex(a, { idx in
        let t0 = Date()
        var qy = MailIndex.Query()
        qy.words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        qy.from = a.str("from")
        qy.to = a.str("to")
        qy.subject = a.str("subject")
        qy.attachmentName = a.str("attachmentName")
        qy.hasAttachments = a.bool("hasAttachments", false)
        qy.unreadOnly = a.bool("unreadOnly", false)
        qy.flaggedOnly = a.bool("flaggedOnly", false)
        if !a.str("since").isEmpty { qy.since = try parseDay(a.str("since")) }
        if !a.str("until").isEmpty { qy.until = Calendar.current.date(byAdding: .day, value: 1, to: try parseDay(a.str("until"))) }
        qy.limit = limit
        let boxes = try scopeMailboxes(idx, account: a.str("account"), mailbox: mailbox, includeTrash: a.bool("includeTrash", false))
        qy.mailboxIds = Array(boxes.keys)
        let hits = Array(dedupe(try idx.search(qy), boxes).prefix(limit))
        let scope = mailbox.isEmpty ? "all mailboxes" : mailbox
        return formatHits(hits, boxes, header: "Search results (\(scope))", elapsed: Date().timeIntervalSince(t0))
    }) { return fast }

    // AppleScript path: body search, or no index available. One mailbox per account (default INBOX).
    let mb = mailbox.isEmpty ? "INBOX" : mailbox
    var conds: [String] = []
    if !query.isEmpty {
        var any = ["subject contains \(q(query))", "sender contains \(q(query))"]
        if a.bool("searchBody", false) { any.append("content contains \(q(query))") }
        conds.append("(" + any.joined(separator: " or ") + ")")
    }
    if !a.str("from").isEmpty { conds.append("sender contains \(q(a.str("from")))") }
    if !a.str("subject").isEmpty { conds.append("subject contains \(q(a.str("subject")))") }
    if a.bool("unreadOnly", false) { conds.append("read status is false") }
    if a.bool("flaggedOnly", false) { conds.append("flagged status is true") }
    var prelude = ""
    if !a.str("since").isEmpty {
        prelude += try dateSnippet(a.str("since"), variable: "sinceDate") + "\n"
        conds.append("date received ≥ sinceDate")
    }
    if !a.str("until").isEmpty {
        prelude += try dateSnippet(a.str("until"), variable: "untilDate") + "\nset untilDate to untilDate + 86400\n"
        conds.append("date received < untilDate")
    }
    if conds.isEmpty { throw ToolError("Give at least one of: query, from, subject, since, until, unreadOnly, flaggedOnly") }
    let raw = try runMail(prelude + (try overAccounts(a.str("account"), """
            set mb to mailbox \(q(mb)) of acct
            set msgs to (messages of mb whose \(conds.joined(separator: " and ")))
            set n to count of msgs
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set out to out & my mcpRow(item i of msgs, acctName, \(q(mb)))
            end repeat
    """)), handlers: rowHandler)
    return formatRows(raw, header: "Search results in \(mb)")
}

// MARK: - Reading

func getMessage(_ a: [String: Any]) throws -> String {
    let id = a.int("messageId", -1)
    guard id >= 0 else { throw ToolError("Missing required argument 'messageId'") }
    let loc = try locate(id, a)
    let maxChars = max(500, a.int("maxChars", 20000))
    let raw = try runMail("""
    set FS to character id 31
    set m to \(messageRef(id: id, account: loc.account, mailbox: loc.mailbox))
    set AppleScript's text item delimiters to ", "
    set toList to (address of every to recipient of m) as string
    set ccList to (address of every cc recipient of m) as string
    set attList to ""
    try
        set attList to (name of every mail attachment of m) as string
    end try
    set AppleScript's text item delimiters to ""
    set dr to ""
    try
        set dr to (date received of m) as «class isot» as string
    end try
    if \(a.bool("markRead", false) ? "true" : "false") then set read status of m to true
    return (sender of m) & FS & toList & FS & ccList & FS & dr & FS & (subject of m) & FS & (message id of m) & FS & attList & FS & (content of m)
    """)
    let f = raw.components(separatedBy: FS)
    guard f.count >= 8 else { return raw }
    var body = f[7...].joined(separator: FS)
    var truncated = ""
    if body.count > maxChars {
        body = String(body.prefix(maxChars))
        truncated = "\n\n[… truncated at \(maxChars) characters; pass a higher maxChars to see more]"
    }
    var lines = ["From:     \(f[0])", "To:       \(f[1])"]
    if !f[2].isEmpty { lines.append("Cc:       \(f[2])") }
    lines += [
        "Date:     \(f[3].replacingOccurrences(of: "T", with: " "))",
        "Subject:  \(f[4])",
        "Account:  \(loc.account)   Mailbox: \(loc.mailbox)   messageId: \(id)",
        "Message-ID: \(f[5])",
    ]
    if !f[6].isEmpty { lines.append("Attachments: \(f[6])  (use mail_save_attachments to save them)") }
    lines += ["", body + truncated]
    return lines.joined(separator: "\n")
}

// MARK: - Attachments

func saveAttachments(_ a: [String: Any]) throws -> String {
    let ids = a.messageIds()
    guard !ids.isEmpty else { throw ToolError("Missing required argument 'messageId' or 'messageIds'") }
    let fm = FileManager.default
    let dirArg = a.str("directory", "~/Downloads/Mail Attachments")
    let dir = URL(fileURLWithPath: (dirArg as NSString).expandingTildeInPath)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let filter = a.str("nameContains")
    let cond = filter.isEmpty ? "true" : "nm contains \(q(filter))"

    var saved: [String] = []
    var problems: [String] = []
    for id in ids {
        let loc: Location
        do { loc = try locate(id, a) } catch { problems.append("message \(id): \(error)"); continue }
        let tmp = dir.appendingPathComponent(".mail-mcp-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let raw: String
        do {
            raw = try runMail("""
            set RS to character id 30
            set m to \(messageRef(id: id, account: loc.account, mailbox: loc.mailbox))
            set out to ""
            set i to 0
            repeat with att in (mail attachments of m)
                set i to i + 1
                set nm to name of att
                if \(cond) then
                    set p to \(q(tmp.path)) & "/" & (i as string) & "_" & nm
                    try
                        save att in POSIX file p
                        set out to out & p & RS
                    on error e
                        set out to out & "ERR:" & nm & ": " & e & RS
                    end try
                end if
            end repeat
            return out
            """)
        } catch { problems.append("message \(id): \(error)"); continue }
        for entry in raw.components(separatedBy: RS) where !entry.isEmpty {
            if entry.hasPrefix("ERR:") { problems.append("message \(id): \(entry.dropFirst(4))"); continue }
            let src = URL(fileURLWithPath: entry)
            var name = src.lastPathComponent
            if let us = name.firstIndex(of: "_") { name = String(name[name.index(after: us)...]) }
            var dest = dir.appendingPathComponent(name)
            let stem = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
                n += 1
            }
            do { try fm.moveItem(at: src, to: dest); saved.append(dest.path) }
            catch { problems.append("\(name): \(error.localizedDescription)") }
        }
    }
    var lines = saved.isEmpty ? ["No attachments saved."] : ["Saved \(saved.count) file(s) to \(dir.path):"] + saved.map { "  \($0)" }
    if !problems.isEmpty {
        lines += ["", "Problems:"] + problems.map { "  \($0)" }
        if problems.contains(where: { $0.contains("-10000") || $0.lowercased().contains("permission") }) {
            lines.append("  (Mail is sandboxed; if a custom directory fails, use one inside ~/Downloads.)")
        }
    }
    return lines.joined(separator: "\n")
}

// MARK: - Composing

/// "Full Name <address>" for an account name or email address.
func senderString(_ from: String) throws -> String? {
    guard !from.isEmpty else { return nil }
    guard let acct = try findAccount(from) else {
        if from.contains("@") { return from }
        throw ToolError("No Mail account matches '\(from)'")
    }
    let addr = acct.emails.first { $0.lowercased() == from.lowercased() } ?? acct.emails.first ?? from
    return acct.fullName.isEmpty ? addr : "\(acct.fullName) <\(addr)>"
}

func composeMessage(_ a: [String: Any]) throws -> String {
    let to = a.list("to")
    guard !to.isEmpty else { throw ToolError("Missing required argument 'to'") }
    let subject = try a.require("subject")
    let body = a.str("body")
    let sendNow = a.bool("send", false)
    let recipients =
        to.map { "make new to recipient at end of to recipients with properties {address:\(q($0))}" } +
        a.list("cc").map { "make new cc recipient at end of cc recipients with properties {address:\(q($0))}" } +
        a.list("bcc").map { "make new bcc recipient at end of bcc recipients with properties {address:\(q($0))}" }
    let attachments = a.list("attachments").map { path -> String in
        "make new attachment with properties {file name:(POSIX file \(q((path as NSString).expandingTildeInPath)) as alias)} at after the last paragraph"
    }
    let sender = try senderString(a.str("from")).map { "set sender of newMsg to \(q($0))" } ?? ""
    try runMail("""
    set newMsg to make new outgoing message with properties {subject:\(q(subject)), content:\(q(body + "\n")), visible:\(sendNow ? "false" : "true")}
    \(sender)
    tell newMsg
        \(recipients.joined(separator: "\n        "))
        \(attachments.joined(separator: "\n        "))
    end tell
    \(sendNow ? "send newMsg" : "activate")
    return "ok"
    """)
    return sendNow
        ? "Sent “\(subject)” to \(to.joined(separator: ", "))."
        : "Draft “\(subject)” opened in Mail for review (not sent). Pass send=true to send directly."
}

func replyMessage(_ a: [String: Any]) throws -> String {
    let id = a.int("messageId", -1)
    guard id >= 0 else { throw ToolError("Missing required argument 'messageId'") }
    let body = try a.require("body")
    let loc = try locate(id, a)
    let sendNow = a.bool("send", false)
    let replyAll = a.bool("replyAll", false)
    try runMail("""
    set m to \(messageRef(id: id, account: loc.account, mailbox: loc.mailbox))
    set r to reply m with opening window\(replyAll ? " and reply to all" : "")
    delay 0.5
    set quoted to ""
    try
        set quoted to content of r
    end try
    set content of r to \(q(body + "\n\n")) & quoted
    \(sendNow ? "send r" : "activate")
    return "ok"
    """)
    return sendNow ? "Reply sent." : "Reply draft opened in Mail for review (not sent). Pass send=true to send directly."
}

// MARK: - Updating (bulk)

/// Archive mailbox for an account: "Archive"/"Archiv", else Gmail's All Mail.
func archiveMailbox(forAccount name: String) throws -> String {
    guard let idx = MailIndex.shared, let acct = try findAccount(name),
          let all = try? idx.mailboxes() else { return "Archive" }
    let boxes = all.filter { $0.accountId == acct.id }
    if let b = boxes.first(where: { ["archive", "archiv"].contains($0.base) }) { return b.path }
    if let b = boxes.first(where: { ["alle nachrichten", "all mail"].contains($0.base) }) { return b.path }
    return "Archive"
}

func updateMessages(_ a: [String: Any]) throws -> String {
    let ids = a.messageIds()
    guard !ids.isEmpty else { throw ToolError("Missing required argument 'messageId' or 'messageIds'") }
    let read = a.optBool("read"), flagged = a.optBool("flagged")
    let moveTo = a.str("moveTo"), archive = a.bool("archive", false), trash = a.bool("trash", false)
    guard read != nil || flagged != nil || !moveTo.isEmpty || archive || trash else {
        throw ToolError("Nothing to do: pass read, flagged, moveTo, archive and/or trash")
    }

    var groups: [Location: [Int]] = [:]
    var problems: [String] = []
    for id in ids {
        do { groups[try locate(id, a), default: []].append(id) } catch { problems.append("\(id): \(error)") }
    }

    var done = 0
    for (loc, groupIds) in groups {
        var actions: [String] = []
        if let read { actions.append("set read status of m to \(read)") }
        if let flagged { actions.append("set flagged status of m to \(flagged)") }
        if trash {
            actions.append("delete m")
        } else if archive {
            actions.append("move m to mailbox \(q(try archiveMailbox(forAccount: loc.account))) of account \(q(loc.account))")
        } else if !moveTo.isEmpty {
            let destAcct = a.str("moveToAccount").isEmpty ? loc.account : try requireAccount(a.str("moveToAccount")).name
            actions.append("move m to mailbox \(q(moveTo)) of account \(q(destAcct))")
        }
        let raw = try runMail("""
        set FS to character id 31
        set mb to mailbox \(q(loc.mailbox)) of account \(q(loc.account))
        set okCount to 0
        set failed to ""
        repeat with mid in {\(groupIds.map(String.init).joined(separator: ", "))}
            try
                set m to (first message of mb whose id is (mid as integer))
                \(actions.joined(separator: "\n            "))
                set okCount to okCount + 1
            on error e
                set failed to failed & (mid as string) & ": " & e & linefeed
            end try
        end repeat
        return (okCount as string) & FS & failed
        """)
        let parts = raw.components(separatedBy: FS)
        done += Int(parts.first ?? "") ?? 0
        if parts.count > 1 {
            problems += parts[1].split(separator: "\n").map(String.init)
        }
    }
    var out = "Updated \(done) of \(ids.count) message(s)."
    if !problems.isEmpty { out += "\nProblems:\n" + problems.map { "  \($0)" }.joined(separator: "\n") }
    return out
}
