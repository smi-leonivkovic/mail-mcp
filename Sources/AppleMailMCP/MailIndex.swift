import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to Mail's own SQLite index (~/Library/Mail/V*/MailData/Envelope Index).
/// Requires Full Disk Access for the host app; when unavailable, tools fall back to AppleScript.
final class MailIndex {
    static let shared: MailIndex? = MailIndex()

    private var db: OpaquePointer?
    let path: String

    private init?() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail").path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            log("Mail index not readable (no Full Disk Access?) — using AppleScript fallback")
            return nil
        }
        let versions = entries.filter { $0.hasPrefix("V") }.compactMap { v -> (Int, String)? in
            Int(v.dropFirst()).map { ($0, v) }
        }.sorted { $0.0 < $1.0 }
        guard let latest = versions.last?.1 else { return nil }
        path = "\(base)/\(latest)/MailData/Envelope Index"
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            log("Could not open Mail index at \(path)")
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 3000)
        guard (try? rows("SELECT ROWID FROM messages LIMIT 1")) != nil,
              (try? rows("SELECT url FROM mailboxes LIMIT 1")) != nil else {
            log("Mail index schema not recognised — using AppleScript fallback")
            sqlite3_close(db)
            return nil
        }
        log("Using Mail index at \(path)")
    }

    func rows(_ sql: String, _ binds: [Any] = []) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ToolError("Mail index query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            if let n = b as? Int { sqlite3_bind_int64(stmt, idx, Int64(n)) }
            else { sqlite3_bind_text(stmt, idx, "\(b)", -1, SQLITE_TRANSIENT) }
        }
        var out: [[String]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let n = sqlite3_column_count(stmt)
                out.append((0..<n).map { c in
                    sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? ""
                })
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw ToolError("Mail index query failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        return out
    }

    // MARK: Mailboxes

    struct Mailbox {
        let rowid: Int
        let accountId: String
        let path: String       // as Mail's AppleScript names it, e.g. "INBOX", "[Gmail]/Alle Nachrichten"
        let total: Int
        let unread: Int
        var base: String { baseName(path) }
    }

    func mailboxes() throws -> [Mailbox] {
        try rows("SELECT ROWID, url, IFNULL(total_count,0), IFNULL(unread_count,0) FROM mailboxes").compactMap { r in
            guard let rowid = Int(r[0]), let (acct, path) = Self.parse(url: r[1]) else { return nil }
            return Mailbox(rowid: rowid, accountId: acct, path: path, total: Int(r[2]) ?? 0, unread: Int(r[3]) ?? 0)
        }
    }

    /// "imap://UUID/%5BGmail%5D/Alle%20Nachrichten" → ("UUID", "[Gmail]/Alle Nachrichten")
    static func parse(url: String) -> (String, String)? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let acct = String(rest[..<slash])
        let rawPath = String(rest[rest.index(after: slash)...])
        let path = (rawPath.removingPercentEncoding ?? rawPath).precomposedStringWithCanonicalMapping
        return path.isEmpty ? nil : (acct, path)
    }

    func mailbox(ofMessage id: Int) throws -> Mailbox? {
        guard let mbId = try rows("SELECT mailbox FROM messages WHERE ROWID = ?", [id]).first.flatMap({ Int($0[0]) }) else { return nil }
        return try mailboxes().first { $0.rowid == mbId }
    }

    // MARK: Search

    struct Hit {
        let id: Int
        let date: Int
        let fromAddress: String
        let fromName: String
        let subject: String
        let read: Bool
        let flagged: Bool
        let mailboxId: Int
        let globalId: String
        let attachments: Int
    }

    struct Query {
        var words: [String] = []          // each word must match subject, sender or snippet
        var from = ""
        var to = ""
        var subject = ""
        var attachmentName = ""
        var since: Date?
        var until: Date?                  // exclusive
        var unreadOnly = false
        var flaggedOnly = false
        var hasAttachments = false
        var mailboxIds: [Int] = []
        var limit = 20
    }

    private func like(_ s: String) -> String {
        "%" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    func search(_ qy: Query) throws -> [Hit] {
        guard !qy.mailboxIds.isEmpty else { return [] }
        var conds = ["m.deleted = 0", "m.mailbox IN (\(qy.mailboxIds.map(String.init).joined(separator: ",")))"]
        var binds: [Any] = []
        let L = "LIKE ? ESCAPE '\\'"

        for w in qy.words {
            conds.append("(s.subject \(L) OR a.address \(L) OR a.comment \(L) OR sm.summary \(L))")
            binds += [like(w), like(w), like(w), like(w)]
        }
        if !qy.from.isEmpty {
            conds.append("(a.address \(L) OR a.comment \(L))")
            binds += [like(qy.from), like(qy.from)]
        }
        if !qy.to.isEmpty {
            conds.append("EXISTS (SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID = r.address WHERE r.message = m.ROWID AND (ra.address \(L) OR ra.comment \(L)))")
            binds += [like(qy.to), like(qy.to)]
        }
        if !qy.subject.isEmpty {
            conds.append("s.subject \(L)")
            binds.append(like(qy.subject))
        }
        if !qy.attachmentName.isEmpty {
            conds.append("EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID AND t.name \(L))")
            binds.append(like(qy.attachmentName))
        } else if qy.hasAttachments {
            conds.append("EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID)")
        }
        if let since = qy.since { conds.append("m.date_received >= ?"); binds.append(Int(since.timeIntervalSince1970)) }
        if let until = qy.until { conds.append("m.date_received < ?"); binds.append(Int(until.timeIntervalSince1970)) }
        if qy.unreadOnly { conds.append("m.read = 0") }
        if qy.flaggedOnly { conds.append("m.flagged = 1") }

        // Over-fetch so de-duplicating Gmail's label copies still leaves `limit` results.
        binds.append(qy.limit * 4 + 10)
        let sql = """
        SELECT m.ROWID, m.date_received, IFNULL(a.address,''), IFNULL(a.comment,''),
               IFNULL(m.subject_prefix,'') || IFNULL(s.subject,''), m.read, m.flagged, m.mailbox,
               IFNULL(m.global_message_id, m.ROWID),
               (SELECT count(*) FROM attachments t WHERE t.message = m.ROWID)
        FROM messages m
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN summaries sm ON sm.ROWID = m.summary
        WHERE \(conds.joined(separator: " AND "))
        ORDER BY m.date_received DESC
        LIMIT ?
        """
        let hits = try rows(sql, binds).map { r in
            Hit(id: Int(r[0]) ?? 0, date: Int(r[1]) ?? 0, fromAddress: r[2], fromName: r[3], subject: r[4],
                read: r[5] == "1", flagged: r[6] == "1", mailboxId: Int(r[7]) ?? 0, globalId: r[8],
                attachments: Int(r[9]) ?? 0)
        }
        return hits
    }

    func attachmentNames(_ id: Int) throws -> [String] {
        try rows("SELECT name FROM attachments WHERE message = ? ORDER BY ROWID", [id]).map { $0[0] }
    }
}
