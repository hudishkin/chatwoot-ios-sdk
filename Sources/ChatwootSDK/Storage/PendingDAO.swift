import Combine
import Foundation

final class PendingDAO {
    private let db: SQLiteDatabase
    private let changes: PassthroughSubject<Void, Never>

    init(db: SQLiteDatabase, changes: PassthroughSubject<Void, Never>) {
        self.db = db
        self.changes = changes
    }

    func upsert(_ pending: StoredPendingMessage) throws {
        try db.run("""
        INSERT INTO pending_messages (echoId, conversationId, content, attachmentPath, attachmentMime,
            kind, state, createdAt, conversationAttributes, posted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(echoId) DO UPDATE SET conversationId = excluded.conversationId, content = excluded.content,
            attachmentPath = excluded.attachmentPath, attachmentMime = excluded.attachmentMime,
            kind = excluded.kind, state = excluded.state, createdAt = excluded.createdAt,
            conversationAttributes = excluded.conversationAttributes, posted = excluded.posted
        """, [
            .text(pending.echoId), .optional(pending.conversationId), .optional(pending.content),
            .optional(pending.attachmentPath), .optional(pending.attachmentMime),
            .text(pending.kind.rawValue), .text(pending.state.rawValue), .integer(Int64(pending.createdAt)),
            .optional(pending.conversationAttributes), .bool(pending.posted)
        ])
        changes.send()
    }

    func get(_ echoId: String) throws -> StoredPendingMessage? {
        try db.query("SELECT * FROM pending_messages WHERE echoId = ?", [.text(echoId)], Self.row).first
    }

    func getAll() throws -> [StoredPendingMessage] {
        try db.query("SELECT * FROM pending_messages ORDER BY createdAt ASC, echoId ASC", [], Self.row)
    }

    func pendingOf(conversationId: Int) throws -> [StoredPendingMessage] {
        try db.query("""
        SELECT * FROM pending_messages WHERE conversationId = ? OR conversationId IS NULL
        ORDER BY createdAt ASC, echoId ASC
        """, [.integer(Int64(conversationId))], Self.row)
    }

    func pendingOfInbox(inboxId: Int) throws -> [StoredPendingMessage] {
        try db.query("""
        SELECT p.* FROM pending_messages p LEFT JOIN conversations c ON p.conversationId = c.id
        WHERE p.conversationId IS NULL OR c.inboxId = ? ORDER BY p.createdAt ASC, p.echoId ASC
        """, [.integer(Int64(inboxId))], Self.row)
    }

    func setState(_ echoId: String, state: StoredPendingMessage.State) throws {
        try db.run("UPDATE pending_messages SET state = ? WHERE echoId = ?", [.text(state.rawValue), .text(echoId)])
        changes.send()
    }

    @discardableResult
    func markQueuedAsFailed() throws -> Int {
        let updated = try db.run("UPDATE pending_messages SET state = 'FAILED' WHERE state = 'QUEUED'")
        if updated > 0 { changes.send() }
        return updated
    }

    func assignConversation(_ echoId: String, conversationId: Int) throws {
        try db.run("UPDATE pending_messages SET conversationId = ? WHERE echoId = ? AND conversationId IS NULL",
                   [.integer(Int64(conversationId)), .text(echoId)])
        changes.send()
    }

    func markPosted(_ echoId: String) throws {
        try db.run("UPDATE pending_messages SET posted = 1 WHERE echoId = ?", [.text(echoId)])
        changes.send()
    }

    func clearPosted(_ echoId: String) throws {
        try db.run("UPDATE pending_messages SET posted = 0 WHERE echoId = ?", [.text(echoId)])
        changes.send()
    }

    func delete(_ echoId: String) throws {
        try db.run("DELETE FROM pending_messages WHERE echoId = ?", [.text(echoId)])
        changes.send()
    }

    // MARK: - Mapping

    static func row(_ row: SQLiteDatabase.Row) -> StoredPendingMessage {
        StoredPendingMessage(
            echoId: row.string(0),
            conversationId: row.optionalInt(1),
            content: row.optionalString(2),
            attachmentPath: row.optionalString(3),
            attachmentMime: row.optionalString(4),
            kind: StoredPendingMessage.Kind(rawValue: row.string(5)) ?? .text,
            state: StoredPendingMessage.State(rawValue: row.string(6)) ?? .failed,
            createdAt: row.int(7),
            conversationAttributes: row.optionalString(8),
            posted: row.bool(9)
        )
    }
}
