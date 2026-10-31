import Combine
import Foundation

final class MessageDAO {
    private let db: SQLiteDatabase
    private let changes: PassthroughSubject<Void, Never>

    init(db: SQLiteDatabase, changes: PassthroughSubject<Void, Never>) {
        self.db = db
        self.changes = changes
    }

    func applyServerMessage(_ message: StoredMessage, attachments: [StoredAttachment], echoId: String?) throws {
        try db.transaction {
            try upsertMessages([message])
            try deleteAttachments(ofMessage: message.id)
            try upsertAttachments(attachments)
            try bumpActivity(conversationId: message.conversationId, at: message.createdAt)
            if let echoId {
                try upsertEcho(StoredEcho(messageId: message.id, echoId: echoId))
                try db.run("DELETE FROM pending_messages WHERE echoId = ?", [.text(echoId)])
            }
        }
        changes.send()
    }

    func echoesOf(conversationId: Int) throws -> [StoredEcho] {
        try db.query("""
        SELECT e.* FROM message_echoes e JOIN messages m ON e.messageId = m.id
        WHERE m.conversationId = ? ORDER BY e.messageId
        """, [.integer(Int64(conversationId))]) { row in
            StoredEcho(messageId: row.int(0), echoId: row.string(1))
        }
    }

    func recordEcho(messageId: Int, echoId: String) throws {
        try upsertEcho(StoredEcho(messageId: messageId, echoId: echoId))
        changes.send()
    }

    func replaceConversations(_ conversations: [StoredConversation], messages: [StoredMessage], attachments: [StoredAttachment]) throws {
        try db.transaction {
            for conversation in conversations {
                var stored = conversation
                if let local = try contactLastSeenAt(conversation.id) {
                    stored.contactLastSeenAt = max(local, conversation.contactLastSeenAt)
                }
                try upsertConversations([stored])
            }
            try upsertMessages(messages)
            for message in messages {
                try deleteAttachments(ofMessage: message.id)
            }
            try upsertAttachments(attachments)
            let grouped = Dictionary(grouping: messages, by: \.conversationId)
            for (id, rows) in grouped where !rows.isEmpty {
                try advanceWatermark(conversationId: id, through: rows.map(\.id).max()!)
            }
        }
        changes.send()
    }

    func syncedThroughId(conversationId: Int) throws -> Int? {
        try db.query("SELECT syncedThroughId FROM sync_watermarks WHERE conversationId = ?",
                     [.integer(Int64(conversationId))]) { $0.int(0) }.first
    }

    func applyMessagesPage(conversationId: Int, messages: [StoredMessage], attachments: [StoredAttachment], syncedThroughId: Int?) throws {
        try db.transaction {
            try upsertMessages(messages)
            for message in messages {
                try deleteAttachments(ofMessage: message.id)
            }
            try upsertAttachments(attachments)
            if let newest = messages.map(\.createdAt).max() {
                try bumpActivity(conversationId: conversationId, at: newest)
            }
            if let syncedThroughId {
                try advanceWatermark(conversationId: conversationId, through: syncedThroughId)
            }
        }
        changes.send()
    }

    func deleteConversation(conversationId: Int) throws {
        try db.transaction {
            try db.run("DELETE FROM attachments WHERE messageId IN (SELECT id FROM messages WHERE conversationId = ?)",
                       [.integer(Int64(conversationId))])
            try db.run("DELETE FROM message_echoes WHERE messageId IN (SELECT id FROM messages WHERE conversationId = ?)",
                       [.integer(Int64(conversationId))])
            try db.run("DELETE FROM messages WHERE conversationId = ?", [.integer(Int64(conversationId))])
            try db.run("DELETE FROM conversations WHERE id = ?", [.integer(Int64(conversationId))])
            try db.run("DELETE FROM sync_watermarks WHERE conversationId = ?", [.integer(Int64(conversationId))])
            try db.run("UPDATE pending_messages SET conversationId = NULL WHERE conversationId = ?",
                       [.integer(Int64(conversationId))])
        }
        changes.send()
    }

    func messagesOf(conversationId: Int) throws -> [MessageWithAttachments] {
        let messages = try db.query(
            "SELECT * FROM messages WHERE conversationId = ? ORDER BY createdAt ASC, id ASC",
            [.integer(Int64(conversationId))], Self.messageRow)
        return try withAttachments(messages)
    }

    func messagesOfInbox(inboxId: Int) throws -> [MessageWithAttachments] {
        let messages = try db.query("""
        SELECT m.* FROM messages m JOIN conversations c ON m.conversationId = c.id
        WHERE c.inboxId = ? ORDER BY m.createdAt ASC, m.id ASC
        """, [.integer(Int64(inboxId))], Self.messageRow)
        return try withAttachments(messages)
    }

    func conversationsOf(inboxId: Int) throws -> [StoredConversation] {
        try db.query("SELECT * FROM conversations WHERE inboxId = ? ORDER BY lastActivityAt DESC, id DESC",
                     [.integer(Int64(inboxId))], ConversationDAO.row)
    }

    func newestMessageId(conversationId: Int) throws -> Int? {
        try db.query("SELECT MAX(id) FROM messages WHERE conversationId = ?",
                     [.integer(Int64(conversationId))]) { $0.optionalInt(0) }.first ?? nil
    }

    func get(_ id: Int) throws -> StoredMessage? {
        try db.query("SELECT * FROM messages WHERE id = ?", [.integer(Int64(id))], Self.messageRow).first
    }

    func unreadCount(inboxId: Int) throws -> Int {
        try db.query("""
        SELECT COUNT(*) FROM messages m JOIN conversations c ON m.conversationId = c.id
        WHERE c.inboxId = ?
        AND (m.type = 1 OR (m.type = 3 AND m.contentType = 'input_csat' AND m.surveyRating IS NULL))
        AND m.isDeleted = 0 AND m.createdAt > c.contactLastSeenAt
        """, [.integer(Int64(inboxId))]) { $0.int(0) }.first ?? 0
    }

    // MARK: - Private

    private func upsertMessages(_ messages: [StoredMessage]) throws {
        for message in messages {
            try db.run("""
            INSERT INTO messages (id, conversationId, content, type, contentType, createdAt, isMine, isDeleted,
                senderName, senderType, surveyDisplay, surveyRating)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET conversationId = excluded.conversationId, content = excluded.content,
                type = excluded.type, contentType = excluded.contentType, createdAt = excluded.createdAt,
                isMine = excluded.isMine, isDeleted = excluded.isDeleted, senderName = excluded.senderName,
                senderType = excluded.senderType, surveyDisplay = excluded.surveyDisplay,
                surveyRating = excluded.surveyRating
            """, Self.messageBindings(message))
        }
    }

    private func upsertAttachments(_ attachments: [StoredAttachment]) throws {
        for attachment in attachments {
            try db.run("""
            INSERT INTO attachments (id, messageId, fileType, dataUrl, thumbUrl, fileSize, width, height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET messageId = excluded.messageId, fileType = excluded.fileType,
                dataUrl = excluded.dataUrl, thumbUrl = excluded.thumbUrl, fileSize = excluded.fileSize,
                width = excluded.width, height = excluded.height
            """, Self.attachmentBindings(attachment))
        }
    }

    private func upsertConversations(_ conversations: [StoredConversation]) throws {
        for conversation in conversations {
            try db.run("""
            INSERT INTO conversations (id, inboxId, status, contactLastSeenAt, agentLastSeenAt, lastActivityAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET inboxId = excluded.inboxId, status = excluded.status,
                contactLastSeenAt = excluded.contactLastSeenAt, agentLastSeenAt = excluded.agentLastSeenAt,
                lastActivityAt = excluded.lastActivityAt
            """, ConversationDAO.bindings(conversation))
        }
    }

    private func upsertEcho(_ echo: StoredEcho) throws {
        try db.run("""
        INSERT INTO message_echoes (messageId, echoId) VALUES (?, ?)
        ON CONFLICT(messageId) DO UPDATE SET echoId = excluded.echoId
        """, [.integer(Int64(echo.messageId)), .text(echo.echoId)])
    }

    private func deleteAttachments(ofMessage messageId: Int) throws {
        try db.run("DELETE FROM attachments WHERE messageId = ?", [.integer(Int64(messageId))])
    }

    private func contactLastSeenAt(_ id: Int) throws -> Int? {
        try db.query("SELECT contactLastSeenAt FROM conversations WHERE id = ?",
                     [.integer(Int64(id))]) { $0.optionalInt(0) }.first ?? nil
    }

    private func bumpActivity(conversationId: Int, at: Int) throws {
        try db.run("UPDATE conversations SET lastActivityAt = ? WHERE id = ? AND lastActivityAt < ?",
                   [.integer(Int64(at)), .integer(Int64(conversationId)), .integer(Int64(at))])
    }

    private func advanceWatermark(conversationId: Int, through id: Int) throws {
        let current = try syncedThroughId(conversationId: conversationId)
        if current == nil || current! < id {
            try db.run("""
            INSERT INTO sync_watermarks (conversationId, syncedThroughId) VALUES (?, ?)
            ON CONFLICT(conversationId) DO UPDATE SET syncedThroughId = excluded.syncedThroughId
            """, [.integer(Int64(conversationId)), .integer(Int64(id))])
        }
    }

    private func withAttachments(_ messages: [StoredMessage]) throws -> [MessageWithAttachments] {
        guard !messages.isEmpty else { return [] }
        let placeholders = messages.map { _ in "?" }.joined(separator: ",")
        let ids = messages.map { SQLiteDatabase.Value.integer(Int64($0.id)) }
        let attachments = try db.query(
            "SELECT * FROM attachments WHERE messageId IN (\(placeholders)) ORDER BY id ASC",
            ids, Self.attachmentRow)
        let echoes = try db.query(
            "SELECT messageId, echoId FROM message_echoes WHERE messageId IN (\(placeholders))",
            ids) { ($0.int(0), $0.string(1)) }
        let grouped = Dictionary(grouping: attachments, by: \.messageId)
        let echoById = Dictionary(echoes, uniquingKeysWith: { first, _ in first })
        return messages.map {
            MessageWithAttachments(message: $0, attachments: grouped[$0.id] ?? [], echoId: echoById[$0.id])
        }
    }

    // MARK: - Mapping

    static func messageBindings(_ m: StoredMessage) -> [SQLiteDatabase.Value] {
        [
            .integer(Int64(m.id)), .integer(Int64(m.conversationId)), .optional(m.content),
            .integer(Int64(m.type)), .text(m.contentType), .integer(Int64(m.createdAt)),
            .bool(m.isMine), .bool(m.isDeleted), .optional(m.senderName), .optional(m.senderType),
            .optional(m.surveyDisplay), .optional(m.surveyRating)
        ]
    }

    static func messageRow(_ row: SQLiteDatabase.Row) -> StoredMessage {
        StoredMessage(
            id: row.int(0),
            conversationId: row.int(1),
            content: row.optionalString(2),
            type: row.int(3),
            contentType: row.string(4),
            createdAt: row.int(5),
            isMine: row.bool(6),
            isDeleted: row.bool(7),
            senderName: row.optionalString(8),
            senderType: row.optionalString(9),
            surveyDisplay: row.optionalString(10),
            surveyRating: row.optionalInt(11)
        )
    }

    static func attachmentBindings(_ a: StoredAttachment) -> [SQLiteDatabase.Value] {
        [
            .integer(Int64(a.id)), .integer(Int64(a.messageId)), .optional(a.fileType),
            .optional(a.dataUrl), .optional(a.thumbUrl), .optional(a.fileSize),
            .optional(a.width), .optional(a.height)
        ]
    }

    static func attachmentRow(_ row: SQLiteDatabase.Row) -> StoredAttachment {
        StoredAttachment(
            id: row.int(0),
            messageId: row.int(1),
            fileType: row.optionalString(2),
            dataUrl: row.optionalString(3),
            thumbUrl: row.optionalString(4),
            fileSize: row.optionalInt(5),
            width: row.optionalInt(6),
            height: row.optionalInt(7)
        )
    }
}
