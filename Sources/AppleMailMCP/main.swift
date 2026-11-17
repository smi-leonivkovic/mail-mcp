// mail-mcp — Apple Mail MCP server in pure Swift, no dependencies.
//
// Reads (list/search/mailboxes) go to Mail's own SQLite index when it's readable
// (Full Disk Access) — milliseconds across every account and folder. Everything
// else, and the fallback, goes through Mail.app via Apple Events, so it uses the
// accounts already configured in Mail: no IMAP passwords, no config file.
// Transport: MCP over stdio, newline-delimited JSON-RPC 2.0.

import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)

typealias Handler = ([String: Any]) throws -> String

func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }
func arrayProp(_ items: String, _ description: String) -> [String: Any] {
    ["type": "array", "items": ["type": items], "description": description]
}

let useIndexProp = prop("boolean", "Set false to skip Mail's index and use the slower AppleScript lookup (default true; it also falls back automatically)")

let locatorProps: [String: Any] = [
    "useIndex": useIndexProp,
    "messageId": prop("integer", "Mail message id (from mail_list_messages / mail_search)"),
    "account": prop("string", "Account of the message — only needed if the Mail index is unavailable"),
    "mailbox": prop("string", "Mailbox of the message — only needed if the Mail index is unavailable (default INBOX)"),
]
let bulkProps: [String: Any] = locatorProps.merging([
    "messageIds": arrayProp("integer", "Several message ids at once (bulk)"),
]) { $1 }

let tools: [(name: String, description: String, properties: [String: Any], required: [String], handler: Handler)] = [
    ("mail_list_accounts", "List the accounts configured in Apple Mail with their email addresses.", [:], [], listAccounts),

    ("mail_list_mailboxes", "List mailboxes (folders) with message and unread counts.",
     ["account": prop("string", "Account name or address (optional; all enabled accounts if empty)"),
      "useIndex": useIndexProp], [], listMailboxes),

    ("mail_list_messages", "List the most recent messages in a mailbox, newest first.",
     ["account": prop("string", "Account name or address (optional; all enabled accounts if empty)"),
      "mailbox": prop("string", "Mailbox name (default INBOX), e.g. Sent, Archive, [Gmail]/Alle Nachrichten"),
      "unreadOnly": prop("boolean", "Only unread messages (default false)"),
      "limit": prop("integer", "Max messages (default 20, max 500)"),
      "useIndex": useIndexProp], [], listMessages),

    ("mail_search", "Search mail across ALL accounts and folders (Trash/Junk excluded unless includeTrash). Fast: uses Mail's index. Every word in 'query' must match subject, sender or preview text.",
     ["query": prop("string", "Words matched against subject, sender name/address and message preview"),
      "from": prop("string", "Sender name or address contains"),
      "to": prop("string", "A To/Cc recipient name or address contains (e.g. search Sent for 'did I reply to X')"),
      "subject": prop("string", "Subject contains"),
      "since": prop("string", "Received on/after YYYY-MM-DD"),
      "until": prop("string", "Received on/before YYYY-MM-DD"),
      "unreadOnly": prop("boolean", "Only unread"),
      "flaggedOnly": prop("boolean", "Only flagged"),
      "hasAttachments": prop("boolean", "Only messages with attachments"),
      "attachmentName": prop("string", "Attachment filename contains, e.g. 'rechnung' or '.pdf'"),
      "account": prop("string", "Limit to one account (name or address)"),
      "mailbox": prop("string", "Limit to one mailbox, e.g. INBOX, Sent, Archive"),
      "includeTrash": prop("boolean", "Also search Trash/Junk (default false)"),
      "searchBody": prop("boolean", "Full-text body search via Mail (slow, one mailbox per account, default INBOX)"),
      "limit": prop("integer", "Max results (default 20, max 500)"),
      "useIndex": useIndexProp], [], searchMessages),

    ("mail_get_message", "Get a message's headers, attachment names and full plain-text body.",
     locatorProps.merging([
        "maxChars": prop("integer", "Truncate body after this many characters (default 20000)"),
        "markRead": prop("boolean", "Mark the message as read (default false)")]) { $1 },
     ["messageId"], getMessage),

    ("mail_save_attachments", "Save attachments of one or more messages to a folder (default ~/Downloads/Mail Attachments). Existing files are never overwritten.",
     bulkProps.merging([
        "directory": prop("string", "Target folder (default ~/Downloads/Mail Attachments; Mail is sandboxed, so folders inside ~/Downloads are safest)"),
        "nameContains": prop("string", "Only attachments whose filename contains this, e.g. '.pdf'")]) { $1 },
     [], saveAttachments),

    ("mail_compose", "Compose a new email. By default opens it in Mail as a draft for the user to review; set send=true to send immediately.",
     ["to": arrayProp("string", "Recipient addresses"),
      "cc": arrayProp("string", "CC addresses (optional)"),
      "bcc": arrayProp("string", "BCC addresses (optional)"),
      "subject": prop("string", "Subject"),
      "body": prop("string", "Plain-text body"),
      "from": prop("string", "Account name or email address to send from (optional; Mail's default otherwise)"),
      "attachments": arrayProp("string", "Absolute file paths to attach (optional)"),
      "send": prop("boolean", "Send immediately instead of opening a draft (default false)")],
     ["to", "subject"], composeMessage),

    ("mail_reply", "Reply to a message. By default opens the reply in Mail for review; set send=true to send immediately.",
     locatorProps.merging([
        "body": prop("string", "Reply text (placed above the quoted original)"),
        "replyAll": prop("boolean", "Reply to all recipients (default false)"),
        "send": prop("boolean", "Send immediately instead of opening a draft (default false)")]) { $1 },
     ["messageId", "body"], replyMessage),

    ("mail_update_messages", "Bulk-update one or more messages: mark read/unread, flag/unflag, archive, move to a mailbox, or move to Trash.",
     bulkProps.merging([
        "read": prop("boolean", "Set read status"),
        "flagged": prop("boolean", "Set flagged status"),
        "archive": prop("boolean", "Move to the account's Archive (Gmail: All Mail)"),
        "trash": prop("boolean", "Move to Trash"),
        "moveTo": prop("string", "Destination mailbox name"),
        "moveToAccount": prop("string", "Account of the destination mailbox (default: same account)")]) { $1 },
     [], updateMessages),
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
            "serverInfo": ["name": "mail-mcp", "version": "1.1.0"],
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
