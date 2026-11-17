// Apple Mail MCP server — pure Swift, no dependencies.
// Talks to Mail.app through Apple Events (NSAppleScript), so it uses whatever
// accounts are already configured in Mail: no IMAP passwords, no config file.
// Transport: MCP over stdio, newline-delimited JSON-RPC 2.0.

import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)

let FS = "\u{1F}"   // field separator (ASCII 31)
let RS = "\u{1E}"   // record separator (ASCII 30)

// MARK: - Logging / output

func log(_ message: String) {
    fputs("[apple-mail-mcp] \(message)\n", stderr)
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func sendResult(id: Any, _ result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func sendError(id: Any?, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
}

// MARK: - AppleScript bridge

struct ScriptError: Error, CustomStringConvertible {
    let description: String
}

/// Quote a Swift string as an AppleScript string literal. Only `\` and `"` are special.
func q(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

@discardableResult
func runScript(_ body: String) throws -> String {
    let source = """
    with timeout of 300 seconds
    tell application "Mail"
    \(body)
    end tell
    end timeout
    """
    guard let script = NSAppleScript(source: source) else {
        throw ScriptError(description: "Could not create AppleScript")
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let num = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        if num == -1743 {
            throw ScriptError(description: "Not allowed to control Mail. Open System Settings → Privacy & Security → Automation and allow this app to control Mail.")
        }
        throw ScriptError(description: "\(msg) (\(num))")
    }
    return result.stringValue ?? ""
}

func records(_ raw: String) -> [[String]] {
    raw.components(separatedBy: RS).filter { !$0.isEmpty }.map { $0.components(separatedBy: FS) }
}

// AppleScript snippet: `mb` = mailbox `mailbox` of account `account`.
func mailboxRef(account: String, mailbox: String) -> String {
    "set mb to mailbox \(q(mailbox)) of account \(q(account))"
}

// AppleScript snippet that builds a date variable `d` from YYYY-MM-DD (locale independent).
func dateSnippet(_ ymd: String, variable: String = "d") throws -> String {
    let parts = ymd.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { throw ScriptError(description: "Invalid date '\(ymd)', expected YYYY-MM-DD") }
    return """
    set \(variable) to current date
    set day of \(variable) to 1
    set year of \(variable) to \(parts[0])
    set month of \(variable) to \(parts[1])
    set day of \(variable) to \(parts[2])
    set time of \(variable) to 0
    """
}

/// AppleScript handler that appends one summary record for message `m` to `out`.
let summaryHandler = """
on mcpRow(m, acctName, mbName)
    tell application "Mail"
        set FS to character id 31
        set RS to character id 30
        set dr to ""
        try
            set dr to (date received of m) as «class isot» as string
        end try
        return (id of m as string) & FS & acctName & FS & mbName & FS & dr & FS & (sender of m) & FS & (subject of m) & FS & (read status of m as string) & FS & (flagged status of m as string) & RS
    end tell
end mcpRow
"""

func runWithHandlers(_ body: String) throws -> String {
    // Handlers must live outside the tell block; run them via a script object.
    let source = """
    \(summaryHandler)
    with timeout of 300 seconds
    tell application "Mail"
    \(body)
    end tell
    end timeout
    """
    guard let script = NSAppleScript(source: source) else { throw ScriptError(description: "Could not create AppleScript") }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let num = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        if num == -1743 {
            throw ScriptError(description: "Not allowed to control Mail. Open System Settings → Privacy & Security → Automation and allow this app to control Mail.")
        }
        throw ScriptError(description: "\(msg) (\(num))")
    }
    return result.stringValue ?? ""
}

func formatSummaries(_ raw: String, header: String) -> String {
    let rows = records(raw)
    if rows.isEmpty { return "\(header)\nNo messages found." }
    var lines = ["\(header) — \(rows.count) message(s):", ""]
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

/// Wraps a per-account loop. `perAccount` is AppleScript operating on `acct`/`acctName`, appending to `out`.
func overAccounts(_ account: String, _ perAccount: String) -> String {
    let accountList = account.isEmpty ? "every account whose enabled is true" : "{account \(q(account))}"
    return """
    set out to ""
    repeat with acct in (\(accountList))
        set acctName to name of acct
        try
    \(perAccount)
        end try
    end repeat
    return out
    """
}

// MARK: - Arguments

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String, _ def: String = "") -> String {
        (self[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? def
    }
    func int(_ k: String, _ def: Int) -> Int {
        if let i = self[k] as? Int { return i }
        if let s = self[k] as? String, let i = Int(s) { return i }
        return def
    }
    func bool(_ k: String, _ def: Bool) -> Bool {
        if let b = self[k] as? Bool { return b }
        if let s = self[k] as? String { return s.lowercased() == "true" }
        return def
    }
    func list(_ k: String) -> [String] {
        if let a = self[k] as? [String] { return a.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let s = self[k] as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return []
    }
    func require(_ k: String) throws -> String {
        let v = str(k)
        if v.isEmpty { throw ScriptError(description: "Missing required argument '\(k)'") }
        return v
    }
}

// MARK: - Tools

func listAccounts(_ a: [String: Any]) throws -> String {
    let raw = try runScript("""
    set FS to character id 31
    set RS to character id 30
    set out to ""
    repeat with acct in every account
        set addrs to ""
        try
            set AppleScript's text item delimiters to ", "
            set addrs to (email addresses of acct) as string
            set AppleScript's text item delimiters to ""
        end try
        set out to out & (name of acct) & FS & addrs & FS & (enabled of acct as string) & FS & ((account type of acct) as string) & RS
    end repeat
    return out
    """)
    let rows = records(raw)
    var lines = ["\(rows.count) Mail account(s):", ""]
    for r in rows where r.count >= 4 {
        lines.append("• \(r[0])\(r[2] == "true" ? "" : " (disabled)")")
        lines.append("  Addresses: \(r[1])")
        lines.append("  Type: \(r[3])")
    }
    return lines.joined(separator: "\n")
}

func listMailboxes(_ a: [String: Any]) throws -> String {
    let raw = try runScript(overAccounts(a.str("account"), """
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

func listMessages(_ a: [String: Any]) throws -> String {
    let mailbox = a.str("mailbox", "INBOX")
    let limit = max(1, min(a.int("limit", 20), 200))
    let unreadOnly = a.bool("unreadOnly", false)
    let selection = unreadOnly
        ? "set msgs to (messages of mb whose read status is false)"
        : "set n0 to count of messages of mb\nif n0 > \(limit) then set n0 to \(limit)\nif n0 = 0 then\nset msgs to {}\nelse\nset msgs to messages 1 thru n0 of mb\nend if"
    let raw = try runWithHandlers(overAccounts(a.str("account"), """
            set mb to mailbox \(q(mailbox)) of acct
            \(selection)
            set n to count of msgs
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set out to out & my mcpRow(item i of msgs, acctName, \(q(mailbox)))
            end repeat
    """))
    return formatSummaries(raw, header: unreadOnly ? "Unread in \(mailbox)" : "Latest in \(mailbox)")
}

func searchMessages(_ a: [String: Any]) throws -> String {
    let query = a.str("query")
    let from = a.str("from")
    let subject = a.str("subject")
    let since = a.str("since")
    let mailbox = a.str("mailbox", "INBOX")
    let limit = max(1, min(a.int("limit", 20), 200))
    let searchBody = a.bool("searchBody", false)

    var conds: [String] = []
    if !query.isEmpty {
        var any = ["subject contains \(q(query))", "sender contains \(q(query))"]
        if searchBody { any.append("content contains \(q(query))") }
        conds.append("(" + any.joined(separator: " or ") + ")")
    }
    if !from.isEmpty { conds.append("sender contains \(q(from))") }
    if !subject.isEmpty { conds.append("subject contains \(q(subject))") }
    if a.bool("unreadOnly", false) { conds.append("read status is false") }
    if a.bool("flaggedOnly", false) { conds.append("flagged status is true") }
    var prelude = ""
    if !since.isEmpty {
        prelude = try dateSnippet(since, variable: "sinceDate")
        conds.append("date received ≥ sinceDate")
    }
    if conds.isEmpty { throw ScriptError(description: "Give at least one of: query, from, subject, since, unreadOnly, flaggedOnly") }

    let raw = try runWithHandlers(prelude + "\n" + overAccounts(a.str("account"), """
            set mb to mailbox \(q(mailbox)) of acct
            set msgs to (messages of mb whose \(conds.joined(separator: " and ")))
            set n to count of msgs
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set out to out & my mcpRow(item i of msgs, acctName, \(q(mailbox)))
            end repeat
    """))
    return formatSummaries(raw, header: "Search results in \(mailbox)")
}

func messageLocator(_ a: [String: Any]) throws -> String {
    let account = try a.require("account")
    let mailbox = a.str("mailbox", "INBOX")
    let id = a.int("messageId", -1)
    guard id >= 0 else { throw ScriptError(description: "Missing required argument 'messageId' (integer)") }
    return """
    \(mailboxRef(account: account, mailbox: mailbox))
    set m to first message of mb whose id is \(id)
    """
}

func getMessage(_ a: [String: Any]) throws -> String {
    let maxChars = max(500, a.int("maxChars", 20000))
    let raw = try runScript("""
    set FS to character id 31
    \(try messageLocator(a))
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
    if read status of m is false and \(a.bool("markRead", false) ? "true" : "false") then set read status of m to true
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
    var lines = [
        "From:     \(f[0])",
        "To:       \(f[1])",
    ]
    if !f[2].isEmpty { lines.append("Cc:       \(f[2])") }
    lines += [
        "Date:     \(f[3].replacingOccurrences(of: "T", with: " "))",
        "Subject:  \(f[4])",
        "Message-ID: \(f[5])",
    ]
    if !f[6].isEmpty { lines.append("Attachments: \(f[6])") }
    lines += ["", body + truncated]
    return lines.joined(separator: "\n")
}

/// Resolve `from` (account name or email address) to a sender string for Mail.
func senderSnippet(_ from: String) -> String {
    guard !from.isEmpty else { return "" }
    return """
    set senderAddr to \(q(from))
    repeat with acct in every account
        if (name of acct) is \(q(from)) then
            set addrList to (get email addresses of acct)
            set senderAddr to item 1 of addrList
            try
                if (full name of acct) is not "" then set senderAddr to (full name of acct) & " <" & senderAddr & ">"
            end try
            exit repeat
        end if
    end repeat
    set sender of newMsg to senderAddr
    """
}

func composeMessage(_ a: [String: Any]) throws -> String {
    let to = a.list("to")
    guard !to.isEmpty else { throw ScriptError(description: "Missing required argument 'to'") }
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
    try runScript("""
    set newMsg to make new outgoing message with properties {subject:\(q(subject)), content:\(q(body + "\n")), visible:\(sendNow ? "false" : "true")}
    \(senderSnippet(a.str("from")))
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
    let body = try a.require("body")
    let sendNow = a.bool("send", false)
    let replyAll = a.bool("replyAll", false)
    try runScript("""
    \(try messageLocator(a))
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

func updateMessage(_ a: [String: Any]) throws -> String {
    var sets: [String] = []
    if let r = a["read"] { sets.append("set read status of m to \((r as? Bool ?? false) ? "true" : "false")") }
    if let f = a["flagged"] { sets.append("set flagged status of m to \((f as? Bool ?? false) ? "true" : "false")") }
    let moveTo = a.str("moveTo")
    if !moveTo.isEmpty {
        let targetAccount = a.str("moveToAccount", a.str("account"))
        sets.append("move m to mailbox \(q(moveTo)) of account \(q(targetAccount))")
    }
    guard !sets.isEmpty else { throw ScriptError(description: "Nothing to do: pass read, flagged and/or moveTo") }
    try runScript("""
    \(try messageLocator(a))
    \(sets.joined(separator: "\n"))
    return "ok"
    """)
    return "Message updated."
}

// MARK: - Tool registry

typealias Handler = ([String: Any]) throws -> String

func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }
let locatorProps: [String: Any] = [
    "messageId": prop("integer", "Mail message id (from mail_list_messages / mail_search)"),
    "account": prop("string", "Account name the message is in"),
    "mailbox": prop("string", "Mailbox the message is in (default INBOX)"),
]

let tools: [(name: String, description: String, properties: [String: Any], required: [String], handler: Handler)] = [
    ("mail_list_accounts", "List the accounts configured in Apple Mail with their email addresses.", [:], [], listAccounts),
    ("mail_list_mailboxes", "List mailboxes (folders) with unread counts.",
     ["account": prop("string", "Account name (optional; all enabled accounts if empty)")], [], listMailboxes),
    ("mail_list_messages", "List the most recent messages in a mailbox, newest first.",
     ["account": prop("string", "Account name (optional; all enabled accounts if empty)"),
      "mailbox": prop("string", "Mailbox name (default INBOX)"),
      "unreadOnly": prop("boolean", "Only unread messages (default false)"),
      "limit": prop("integer", "Max messages per account (default 20, max 200)")], [], listMessages),
    ("mail_search", "Search messages by sender, subject, date and status. Body search is optional and slow.",
     ["query": prop("string", "Text matched against subject or sender"),
      "from": prop("string", "Sender contains"),
      "subject": prop("string", "Subject contains"),
      "since": prop("string", "Only messages received on/after YYYY-MM-DD"),
      "unreadOnly": prop("boolean", "Only unread"),
      "flaggedOnly": prop("boolean", "Only flagged"),
      "searchBody": prop("boolean", "Also match query against message body (slow on large mailboxes)"),
      "account": prop("string", "Account name (optional; all enabled accounts if empty)"),
      "mailbox": prop("string", "Mailbox name (default INBOX)"),
      "limit": prop("integer", "Max results per account (default 20, max 200)")], [], searchMessages),
    ("mail_get_message", "Get a message's headers, attachment names and full plain-text body.",
     locatorProps.merging([
        "maxChars": prop("integer", "Truncate body after this many characters (default 20000)"),
        "markRead": prop("boolean", "Mark the message as read (default false)")]) { $1 },
     ["messageId", "account"], getMessage),
    ("mail_compose", "Compose a new email. By default opens it in Mail as a draft for the user to review; set send=true to send immediately.",
     ["to": ["type": "array", "items": ["type": "string"], "description": "Recipient addresses"],
      "cc": ["type": "array", "items": ["type": "string"], "description": "CC addresses (optional)"],
      "bcc": ["type": "array", "items": ["type": "string"], "description": "BCC addresses (optional)"],
      "subject": prop("string", "Subject"),
      "body": prop("string", "Plain-text body"),
      "from": prop("string", "Account name or email address to send from (optional; Mail's default otherwise)"),
      "attachments": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths to attach (optional)"],
      "send": prop("boolean", "Send immediately instead of opening a draft (default false)")],
     ["to", "subject"], composeMessage),
    ("mail_reply", "Reply to a message. By default opens the reply in Mail for review; set send=true to send immediately.",
     locatorProps.merging([
        "body": prop("string", "Reply text (placed above the quoted original)"),
        "replyAll": prop("boolean", "Reply to all recipients (default false)"),
        "send": prop("boolean", "Send immediately instead of opening a draft (default false)")]) { $1 },
     ["messageId", "account", "body"], replyMessage),
    ("mail_update_message", "Mark a message read/unread, flag/unflag it, or move it to another mailbox (e.g. Archive, Trash).",
     locatorProps.merging([
        "read": prop("boolean", "Set read status"),
        "flagged": prop("boolean", "Set flagged status"),
        "moveTo": prop("string", "Destination mailbox name"),
        "moveToAccount": prop("string", "Account of the destination mailbox (default: same account)")]) { $1 },
     ["messageId", "account"], updateMessage),
]

// MARK: - JSON-RPC dispatch

func handle(_ json: [String: Any]) {
    guard let method = json["method"] as? String else { return }
    let id = json["id"]
    let params = json["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        guard let id else { return }
        sendResult(id: id, [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "apple-mail-mcp", "version": "1.0.0"],
        ])
    case "ping":
        if let id { sendResult(id: id, [:]) }
    case "tools/list":
        guard let id else { return }
        sendResult(id: id, ["tools": tools.map { t in
            ["name": t.name, "description": t.description,
             "inputSchema": ["type": "object", "properties": t.properties, "required": t.required]] as [String: Any]
        }])
    case "tools/call":
        guard let id else { return }
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            sendError(id: id, code: -32602, message: "Unknown tool: \(name)")
            return
        }
        do {
            let text = try tool.handler(args)
            sendResult(id: id, ["content": [["type": "text", "text": text]]])
        } catch {
            log("\(name) failed: \(error)")
            sendResult(id: id, ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true])
        }
    default:
        if method.hasPrefix("notifications/") { return }
        if let id { sendError(id: id, code: -32601, message: "Method not found: \(method)") }
    }
}

// MARK: - Main loop (main thread; NSAppleScript is not thread-safe)

var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }  // EOF
    buffer.append(chunk)
    while let nl = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<nl]
        buffer.removeSubrange(buffer.startIndex...nl)
        guard !line.isEmpty else { continue }
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            sendError(id: nil, code: -32700, message: "Parse error")
            continue
        }
        handle(obj)
    }
}
