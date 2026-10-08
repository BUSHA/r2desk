import Foundation

public enum FinderIdentity {
    public static func domain(connection: Connection, bucket: String) -> String {
        "r2desk." + connection.id.uuidString + "." + connection.accountID + "." + (connection.jurisdiction.isEmpty ? "default" : connection.jurisdiction) + "." + bucket
    }
    public static func item(_ key: String) -> String { Data(key.utf8).base64EncodedString() }
    public static func key(_ identifier: String) throws -> String {
        guard let data = Data(base64Encoded: identifier), let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw StorageError.message("The Finder item ID is invalid.")
        }
        try validate(key); return key
    }
    public static func validate(_ key: String) throws {
        let path = key.hasSuffix("/") ? String(key.dropLast()) : key
        for part in path.split(separator: "/", omittingEmptySubsequences: false) { try FilePaths.validateName(String(part)) }
    }
    public static func parent(_ key: String) -> String {
        let path = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }
}

/// Durable item IDs, metadata, and a bounded change journal. No access keys or contents are stored here.
public struct FinderCatalog: Codable, Sendable {
    public struct Change: Codable, Sendable {
        public let sequence: Int64
        public let identifier: String
        public let item: RemoteItem
        public let deleted: Bool
        public let previousParent: String?
        private enum CodingKeys: String, CodingKey { case sequence, identifier, item, deleted, previousParent }
        init(sequence: Int64, identifier: String, item: RemoteItem, deleted: Bool, previousParent: String? = nil) {
            self.sequence = sequence; self.identifier = identifier; self.item = item; self.deleted = deleted; self.previousParent = previousParent
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sequence = try c.decode(Int64.self, forKey: .sequence); item = try c.decode(RemoteItem.self, forKey: .item)
            deleted = try c.decode(Bool.self, forKey: .deleted)
            identifier = try c.decodeIfPresent(String.self, forKey: .identifier) ?? FinderIdentity.item(item.key)
            previousParent = try c.decodeIfPresent(String.self, forKey: .previousParent)
        }
    }
    private var capabilitiesVersion = 1
    private var epoch = UUID()
    private var sequence: Int64 = 0
    private var floor: Int64 = 0
    private var records: [String: RemoteItem] = [:]
    private var identifiers: [String: String] = [:]
    private var journal: [Change] = []
    public private(set) var folders: Set<String> = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case epoch, sequence, floor, records, identifiers, journal, folders, capabilitiesVersion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capabilitiesVersion = try c.decodeIfPresent(Int.self, forKey: .capabilitiesVersion) ?? 0
        epoch = try c.decode(UUID.self, forKey: .epoch); sequence = try c.decode(Int64.self, forKey: .sequence)
        floor = try c.decode(Int64.self, forKey: .floor); records = try c.decode([String: RemoteItem].self, forKey: .records)
        journal = try c.decode([Change].self, forKey: .journal); folders = try c.decode(Set<String>.self, forKey: .folders)
        // Keep IDs from the first read-only build, including files already downloaded by Finder.
        identifiers = try c.decodeIfPresent([String: String].self, forKey: .identifiers) ?? records.mapValues { FinderIdentity.item($0.key) }
    }
    @discardableResult public mutating func prepareForWriting() -> Bool {
        guard capabilitiesVersion < 1 else { return false }
        capabilitiesVersion = 1
        for item in items { append(item, deleted: false) }
        return true
    }
    public var items: [RemoteItem] { records.values.sorted { $0.key < $1.key } }
    public func item(key: String) -> RemoteItem? { records[key] }
    public func identifier(key: String) -> String { identifiers[key] ?? FinderIdentity.item(key) }
    public func key(identifier: String) -> String? { identifiers.first { $0.value == identifier }?.key }
    public var anchor: Data { Data("\(epoch.uuidString):\(sequence)".utf8) }

    public mutating func replace(prefix: String, items: [RemoteItem]) throws {
        try validate(prefix: prefix, items: items)
        let old = records.values.filter { FinderIdentity.parent($0.key) == prefix }
        let keys = Set(items.map(\.key))
        for item in old where !keys.contains(item.key) { remove(key: item.key) }
        for item in items where records[item.key] != item { upsert(item) }
        folders.insert(prefix)
    }
    public mutating func upsert(_ item: RemoteItem) {
        if identifiers[item.key] == nil { identifiers[item.key] = "item-" + UUID().uuidString }
        records[item.key] = item; append(item, deleted: false)
    }
    public mutating func remove(key: String) {
        let removed = records.values.filter { $0.key == key || (key.hasSuffix("/") && $0.key.hasPrefix(key)) }
        for item in removed { append(item, deleted: true); records.removeValue(forKey: item.key); identifiers.removeValue(forKey: item.key) }
        if key.hasSuffix("/") { folders = folders.filter { !$0.hasPrefix(key) } }
    }
    public mutating func move(from source: String, to destination: String) throws {
        try FinderIdentity.validate(destination)
        guard records[source] != nil, records[destination] == nil,
              !source.hasSuffix("/") || !destination.hasPrefix(source) else { throw StorageError.message("The Finder move is invalid.") }
        let moving = records.values.filter { $0.key == source || (source.hasSuffix("/") && $0.key.hasPrefix(source)) }
        for item in moving {
            let key = destination + item.key.dropFirst(source.count)
            let id = identifier(key: item.key)
            records.removeValue(forKey: item.key); identifiers.removeValue(forKey: item.key)
            let changed = RemoteItem(key: key, isFolder: item.isFolder, size: item.size, modified: item.modified, etag: item.etag)
            records[key] = changed; identifiers[key] = id
            append(changed, deleted: false, previousParent: FinderIdentity.parent(item.key))
        }
        folders = Set(folders.map { $0.hasPrefix(source) ? destination + $0.dropFirst(source.count) : $0 })
    }
    public func changes(since anchor: Data, prefix: String? = nil) throws -> [Change] {
        guard let text = String(data: anchor, encoding: .utf8) else { throw expired() }
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[0] == Substring(epoch.uuidString), let value = Int64(parts[1]), value >= floor, value <= sequence else { throw expired() }
        var latest: [String: Change] = [:]
        for change in journal where change.sequence > value {
            if prefix == nil || FinderIdentity.parent(change.item.key) == prefix || change.previousParent == prefix { latest[change.identifier] = change }
        }
        return latest.values.sorted { $0.sequence < $1.sequence }
    }
    private func validate(prefix: String, items: [RemoteItem]) throws {
        var names = Set<String>()
        for item in items {
            try FinderIdentity.validate(item.key)
            guard FinderIdentity.parent(item.key) == prefix,
                  names.insert(item.name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw StorageError.message("This folder has names that Finder cannot show safely. Use R2 Desk to browse it.")
            }
        }
    }
    private func expired() -> Error { StorageError.message("The Finder change history has expired.") }
    private mutating func append(_ item: RemoteItem, deleted: Bool, previousParent: String? = nil) {
        sequence += 1
        journal.append(Change(sequence: sequence, identifier: identifier(key: item.key), item: item, deleted: deleted, previousParent: previousParent))
        if journal.count > 2000 { floor = journal.removeFirst().sequence }
    }
}
