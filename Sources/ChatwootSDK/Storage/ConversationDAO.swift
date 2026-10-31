import Combine
import Foundation

struct ConversationSummary: Equatable {
    let id: Int
    let status: String
    let lastActivityAt: Int
    let lastMessagePreview: String?
    let unread: Int
}

final class ConversationDAO {
    private let db: SQLiteDatabase
    private let changes: PassthroughSubject<Void, Never>

    init(db: SQLiteDatabase, changes: PassthroughSubject<Void, Never>) {
        self.db = db
        self.changes = changes
    }

    func upsert(_ conversation: StoredConversation) throws {
        try db.run("""
        INSERT INTO conversations (id, inboxId, status, contactLastSeenAt, agentLastSeenAt, lastActivityAt)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET inboxId = excluded.inboxId, status = excluded.status,
            contactLastSeenAt = excluded.contactLastSeenAt, agentLastSeenAt = excluded.agentLastSeenAt,
            lastActivityAt = excluded.lastActivityAt
        """, Self.bindings(conversation))
        changes.send()
    }

    func get(_ id: Int) throws -> StoredConversation? {
        try db.query("SELECT * FROM conversations WHERE id = ?", [.integer(Int64(id))], Self.row).first
    }

    func allOrderedByActivity() throws -> [StoredConversation] {
        try db.query("SELECT * FROM conversations ORDER BY lastActivityAt DESC", [], Self.row)
    }

    func summaries(inboxId: Int) throws -> [ConversationSummary] {
        try db.query("""
        SELECT c.id AS id, c.status AS status, c.lastActivityAt AS lastActivityAt,
            (SELECT m.content FROM messages m WHERE m.conversationId = c.id AND m.isDeleted = 0 AND m.type != 2
            ORDER BY m.createdAt DESC, m.id DESC LIMIT 1) AS lastMessagePreview,
            (SELECT COUNT(*) FROM messages m WHERE m.conversationId = c.id
            AND (m.type = 1 OR (m.type = 3 AND m.contentType = 'input_csat' AND m.surveyRating IS NULL))
            AND m.isDeleted = 0 AND m.createdAt > c.contactLastSeenAt) AS unread
        FROM conversations c WHERE c.inboxId = ? ORDER BY c.lastActivityAt DESC, c.id DESC
        """, [.integer(Int64(inboxId))]) { row in
            ConversationSummary(
                id: row.int(0),
                status: row.string(1),
                lastActivityAt: row.int(2),
                lastMessagePreview: row.optionalString(3),
                unread: row.int(4)
            )
        }
    }

    func insertIfAbsent(_ conversation: StoredConversation) throws -> Bool {
        let inserted = try db.run("""
        INSERT OR IGNORE INTO conversations (id, inboxId, status, contactLastSeenAt, agentLastSeenAt, lastActivityAt)
        VALUES (?, ?, ?, ?, ?, ?)
        """, Self.bindings(conversation))
        if inserted > 0 { changes.send() }
        return inserted > 0
    }

    func mergeFromServer(id: Int, inboxId: Int, status: String, contactLastSeenAt: Int, agentLastSeenAt: Int, lastActivityAt: Int) throws {
        try db.run("""
        UPDATE conversations SET inboxId = ?, status = ?,
            contactLastSeenAt = MAX(contactLastSeenAt, ?),
            agentLastSeenAt = MAX(agentLastSeenAt, ?),
            lastActivityAt = MAX(lastActivityAt, ?)
        WHERE id = ?
        """, [
            .integer(Int64(inboxId)), .text(status),
            .integer(Int64(contactLastSeenAt)), .integer(Int64(agentLastSeenAt)),
            .integer(Int64(lastActivityAt)), .integer(Int64(id))
        ])
        changes.send()
    }

    func updateStatus(_ id: Int, status: String) throws {
        try db.run("UPDATE conversations SET status = ? WHERE id = ?", [.text(status), .integer(Int64(id))])
        changes.send()
    }

    func markSeen(_ id: Int, at: Int) throws {
        try db.run("UPDATE conversations SET contactLastSeenAt = ? WHERE id = ? AND contactLastSeenAt < ?",
                   [.integer(Int64(at)), .integer(Int64(id)), .integer(Int64(at))])
        changes.send()
    }

    func markInboxSeen(_ inboxId: Int, at: Int) throws {
        try db.run("UPDATE conversations SET contactLastSeenAt = ? WHERE inboxId = ? AND contactLastSeenAt < ?",
                   [.integer(Int64(at)), .integer(Int64(inboxId)), .integer(Int64(at))])
        changes.send()
    }

    // MARK: - Mapping

    static func bindings(_ c: StoredConversation) -> [SQLiteDatabase.Value] {
        [
            .integer(Int64(c.id)), .integer(Int64(c.inboxId)), .text(c.status),
            .integer(Int64(c.contactLastSeenAt)), .integer(Int64(c.agentLastSeenAt)),
            .integer(Int64(c.lastActivityAt))
        ]
    }

    static func row(_ row: SQLiteDatabase.Row) -> StoredConversation {
        StoredConversation(
            id: row.int(0),
            inboxId: row.int(1),
            status: row.string(2),
            contactLastSeenAt: row.int(3),
            agentLastSeenAt: row.int(4),
            lastActivityAt: row.int(5)
        )
    }
}
