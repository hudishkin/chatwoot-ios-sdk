import Combine
import Foundation

final class ChatwootDatabase: @unchecked Sendable {
    let db: SQLiteDatabase
    let messages: MessageDAO
    let conversations: ConversationDAO
    let pending: PendingDAO

    let changes = PassthroughSubject<Void, Never>()

    private init(db: SQLiteDatabase) {
        self.db = db
        self.messages = MessageDAO(db: db, changes: changes)
        self.conversations = ConversationDAO(db: db, changes: changes)
        self.pending = PendingDAO(db: db, changes: changes)
    }

    static func open(directory: URL? = nil, fileManager: FileManager = .default) throws -> ChatwootDatabase {
        let directory = directory ?? SDKDirectory.data(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("chatwoot.db").path
        let database = ChatwootDatabase(db: try SQLiteDatabase(path: path))
        try database.createSchema()
        return database
    }

    static func inMemory() throws -> ChatwootDatabase {
        let database = ChatwootDatabase(db: try SQLiteDatabase.inMemory())
        try database.createSchema()
        return database
    }

    func wipe() throws {
        try db.transaction {
            for table in Self.tables {
                try db.run("DELETE FROM \(table)")
            }
        }
        changes.send()
    }

    // MARK: - Schema

    private static let tables = [
        "conversations", "messages", "attachments", "pending_messages", "message_echoes", "sync_watermarks"
    ]

    private func createSchema() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS conversations (
            id INTEGER PRIMARY KEY,
            inboxId INTEGER NOT NULL,
            status TEXT NOT NULL,
            contactLastSeenAt INTEGER NOT NULL,
            agentLastSeenAt INTEGER NOT NULL,
            lastActivityAt INTEGER NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY,
            conversationId INTEGER NOT NULL,
            content TEXT,
            type INTEGER NOT NULL,
            contentType TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            isMine INTEGER NOT NULL,
            isDeleted INTEGER NOT NULL,
            senderName TEXT,
            senderType TEXT,
            surveyDisplay TEXT,
            surveyRating INTEGER
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS index_messages_conversationId ON messages(conversationId)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS attachments (
            id INTEGER PRIMARY KEY,
            messageId INTEGER NOT NULL,
            fileType TEXT,
            dataUrl TEXT,
            thumbUrl TEXT,
            fileSize INTEGER,
            width INTEGER,
            height INTEGER
        )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS index_attachments_messageId ON attachments(messageId)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS pending_messages (
            echoId TEXT PRIMARY KEY,
            conversationId INTEGER,
            content TEXT,
            attachmentPath TEXT,
            attachmentMime TEXT,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            conversationAttributes TEXT,
            posted INTEGER NOT NULL DEFAULT 0
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS message_echoes (
            messageId INTEGER PRIMARY KEY,
            echoId TEXT NOT NULL
        )
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS sync_watermarks (
            conversationId INTEGER PRIMARY KEY,
            syncedThroughId INTEGER NOT NULL
        )
        """)
        try db.execute("PRAGMA user_version = 1")
    }
}
