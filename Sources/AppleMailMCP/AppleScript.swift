import Foundation

let FS = "\u{1F}"   // field separator (ASCII 31)
let RS = "\u{1E}"   // record separator (ASCII 30)

/// Quote a Swift string as an AppleScript string literal. Only `\` and `"` are special.
func q(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// Handler used by the AppleScript fallback paths to emit one summary record.
let rowHandler = """
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

/// Run AppleScript inside `tell application "Mail"`. Must be called on the main thread.
@discardableResult
func runMail(_ body: String, handlers: String = "") throws -> String {
    let source = """
    \(handlers)
    with timeout of 300 seconds
    tell application "Mail"
    \(body)
    end tell
    end timeout
    """
    guard let script = NSAppleScript(source: source) else { throw ToolError("Could not create AppleScript") }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let num = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        if num == -1743 {
            throw ToolError("Not allowed to control Mail. Open System Settings → Privacy & Security → Automation and allow this app to control Mail.")
        }
        if num == -1719 || num == -1728 {
            throw ToolError("Mail couldn't find that message or mailbox (it may have been moved or deleted). \(msg)")
        }
        throw ToolError("\(msg) (\(num))")
    }
    return result.stringValue ?? ""
}

func records(_ raw: String) -> [[String]] {
    raw.components(separatedBy: RS).filter { !$0.isEmpty }.map { $0.components(separatedBy: FS) }
}

/// AppleScript expression for a message.
func messageRef(id: Int, account: String, mailbox: String) -> String {
    "(first message of mailbox \(q(mailbox)) of account \(q(account)) whose id is \(id))"
}

/// AppleScript snippet that builds a date variable from YYYY-MM-DD (locale independent).
func dateSnippet(_ ymd: String, variable: String) throws -> String {
    _ = try parseDay(ymd)
    let p = ymd.split(separator: "-").compactMap { Int($0) }
    return """
    set \(variable) to current date
    set day of \(variable) to 1
    set year of \(variable) to \(p[0])
    set month of \(variable) to \(p[1])
    set day of \(variable) to \(p[2])
    set time of \(variable) to 0
    """
}

// MARK: - Accounts (cached)

struct MailAccount {
    let name: String
    let id: String
    let enabled: Bool
    let emails: [String]
    let type: String
    let fullName: String
}

private var accountCache: [MailAccount]?

func mailAccounts(refresh: Bool = false) throws -> [MailAccount] {
    if let accountCache, !refresh { return accountCache }
    let raw = try runMail("""
    set FS to character id 31
    set RS to character id 30
    set out to ""
    repeat with acct in every account
        set addrs to ""
        set fn to ""
        try
            set AppleScript's text item delimiters to ","
            set addrs to (email addresses of acct) as string
            set AppleScript's text item delimiters to ""
        end try
        try
            set fn to full name of acct
        end try
        set out to out & (name of acct) & FS & (id of acct) & FS & (enabled of acct as string) & FS & addrs & FS & ((account type of acct) as string) & FS & fn & RS
    end repeat
    return out
    """)
    let list = records(raw).filter { $0.count >= 6 }.map {
        MailAccount(name: $0[0], id: $0[1], enabled: $0[2] == "true",
                    emails: $0[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    type: $0[4], fullName: $0[5])
    }
    accountCache = list
    return list
}

/// Find an account by name or email address (case-insensitive).
func findAccount(_ key: String) throws -> MailAccount? {
    let k = key.lowercased()
    let match: ([MailAccount]) -> MailAccount? = { accts in
        accts.first { $0.name.lowercased() == k } ?? accts.first { $0.enabled && $0.emails.contains { $0.lowercased() == k } }
            ?? accts.first { $0.emails.contains { $0.lowercased() == k } }
    }
    if let a = match(try mailAccounts()) { return a }
    return match(try mailAccounts(refresh: true))
}

func requireAccount(_ key: String) throws -> MailAccount {
    guard let a = try findAccount(key) else {
        let names = (try? mailAccounts().map(\.name).joined(separator: ", ")) ?? ""
        throw ToolError("Account '\(key)' not found. Available: \(names)")
    }
    return a
}
