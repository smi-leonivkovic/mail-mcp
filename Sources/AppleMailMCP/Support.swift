import Foundation

// MARK: - Output / logging

func log(_ message: String) {
    fputs("[mail-mcp] \(message)\n", stderr)
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

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Arguments

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String, _ def: String = "") -> String {
        let v = (self[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? def : v
    }
    func int(_ k: String, _ def: Int) -> Int {
        if let i = self[k] as? Int { return i }
        if let d = self[k] as? Double { return Int(d) }
        if let s = self[k] as? String, let i = Int(s) { return i }
        return def
    }
    func optBool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let s = self[k] as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return nil
    }
    func bool(_ k: String, _ def: Bool) -> Bool { optBool(k) ?? def }
    func list(_ k: String) -> [String] {
        if let a = self[k] as? [Any] { return a.map { "\($0)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let s = self[k] as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let i = self[k] as? Int { return [String(i)] }
        return []
    }
    func require(_ k: String) throws -> String {
        let v = str(k)
        if v.isEmpty { throw ToolError("Missing required argument '\(k)'") }
        return v
    }
    /// messageId (single) and/or messageIds (array) → [Int]
    func messageIds() -> [Int] {
        var ids = list("messageIds").compactMap { Int($0) }
        let single = int("messageId", -1)
        if single >= 0 { ids.insert(single, at: 0) }
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Dates

func parseDay(_ ymd: String) throws -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    guard let d = f.date(from: ymd) else { throw ToolError("Invalid date '\(ymd)', expected YYYY-MM-DD") }
    return d
}

func displayDate(_ epoch: Int) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
}

// MARK: - Mailbox names

/// Names (last path component, lowercased) of mailboxes excluded from "search everywhere" by default.
let trashLikeMailboxes: Set<String> = [
    "trash", "papierkorb", "deleted messages", "deleted items", "gelöschte elemente", "gelöschte objekte",
    "junk", "spam", "junk-e-mail", "junk e-mail", "werbung",
]

/// Gmail virtual folders that duplicate messages living elsewhere; deprioritised when de-duplicating.
let aggregateMailboxes: Set<String> = [
    "alle nachrichten", "all mail", "wichtig", "important", "markiert", "starred",
]

func baseName(_ path: String) -> String {
    (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
}
