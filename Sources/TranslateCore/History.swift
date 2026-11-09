import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var original: String
    public var translation: String
    public var source: String
    public var target: String

    public init(id: UUID = UUID(), date: Date = Date(), original: String, translation: String,
                source: String, target: String) {
        self.id = id
        self.date = date
        self.original = original
        self.translation = translation
        self.source = source
        self.target = target
    }
}

/// Recent translations, newest first, saved as JSON. Repeating a translation moves it to the top.
public final class History: @unchecked Sendable {
    public let file: URL
    public let limit: Int
    private let lock = NSLock()
    private var items: [HistoryEntry]

    public init(file: URL, limit: Int = 100) {
        self.file = file
        self.limit = limit
        let data = try? Data(contentsOf: file)
        items = data.flatMap { try? Self.decoder.decode([HistoryEntry].self, from: $0) } ?? []
    }

    public var entries: [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    public func add(_ entry: HistoryEntry) {
        lock.lock()
        items.removeAll { $0.original == entry.original && $0.target == entry.target }
        items.insert(entry, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        let snapshot = items
        lock.unlock()
        save(snapshot)
    }

    public func clear() {
        lock.lock()
        items = []
        lock.unlock()
        save([])
    }

    private func save(_ snapshot: [HistoryEntry]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(snapshot) { try? data.write(to: file, options: .atomic) }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
