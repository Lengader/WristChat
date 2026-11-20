import Foundation

enum ReasoningMode: String, CaseIterable, Codable, Identifiable {
    case automatic, fast, deep

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Авто"
        case .fast: "Быстро"
        case .deep: "Думать дольше"
        }
    }

    var effort: String? {
        switch self {
        case .automatic: nil
        case .fast: "low"
        case .deep: "high"
        }
    }
}

struct ChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    enum Ending: String, Codable { case stopped, interrupted }

    var id = UUID()
    let role: Role
    var content: String
    var photo: Data?
    var ending: Ending?
}

struct ChatThread: Identifiable, Codable {
    var id = UUID()
    var messages: [ChatMessage] = []
    var updated = Date()

    var title: String {
        let firstLine = messages.first?.content.split(whereSeparator: \.isNewline).first ?? ""
        return firstLine.isEmpty ? (messages.isEmpty ? "Новый чат" : "Фото") : String(firstLine.prefix(65))
    }
}

struct ReasoningChange: Codable {
    let subject: String
    let threadID: UUID?
    let mode: ReasoningMode?
    let stamp: UUID
    let date: Date

    init(subject: String, threadID: UUID?, mode: ReasoningMode?, date: Date = Date()) {
        self.subject = subject
        self.threadID = threadID
        self.mode = mode
        stamp = UUID()
        self.date = date
    }

    var key: String { threadID?.uuidString ?? "default" }

    func isNewer(than other: ReasoningChange) -> Bool {
        date == other.date ? stamp.uuidString > other.stamp.uuidString : date > other.date
    }
}

struct ChatBook: Codable {
    var revision = 0
    var threads: [ChatThread] = []
    var changes: [String: ReasoningChange] = [:]

    var latestThreads: [ChatThread] { threads.sorted { $0.updated > $1.updated } }

    func preference(for threadID: UUID?) -> ReasoningMode? {
        changes[threadID?.uuidString ?? "default"]?.mode
    }

    func mode(for threadID: UUID) -> ReasoningMode {
        preference(for: threadID) ?? preference(for: nil) ?? .automatic
    }

    @discardableResult
    mutating func apply(_ change: ReasoningChange) -> Bool {
        if let previous = changes[change.key], !change.isNewer(than: previous) { return false }
        changes[change.key] = change
        return true
    }

    mutating func add(_ messages: [ChatMessage], to id: UUID) {
        if let index = threads.firstIndex(where: { $0.id == id }) {
            threads[index].messages += messages
            threads[index].updated = Date()
        } else {
            threads.append(ChatThread(id: id, messages: messages))
        }
    }
}

struct HistorySnapshot: Codable {
    let subject: String
    let book: ChatBook
}

enum ChatStorage {
    private static func path(_ subject: String, prefix: String) -> URL {
        let suffix = Data(subject.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return URL.applicationSupportDirectory.appending(path: prefix + suffix + ".json")
    }

    static func load(_ subject: String, migrateLegacy: Bool = false) -> ChatBook {
        if let data = try? Data(contentsOf: path(subject, prefix: "history-")),
           let book = try? JSONDecoder().decode(ChatBook.self, from: data) { return book }
        if migrateLegacy, let data = try? Data(contentsOf: path(subject, prefix: "chat-")),
           let messages = try? JSONDecoder().decode([ChatMessage].self, from: data), !messages.isEmpty {
            let book = ChatBook(threads: [ChatThread(messages: messages)])
            // Keep the migrated chat ID stable across launches, before the first new turn.
            try? save(book, for: subject)
            return book
        }
        return ChatBook()
    }

    static func save(_ book: ChatBook, for subject: String) throws {
        let url = path(subject, prefix: "history-")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(book).write(to: url, options: .atomic)
    }
}
