import FileProvider
import Security
import R2Core
import R2FinderShared
import CryptoKit

/// The extension has its own sandbox and Keychain. Keys arrive only over the restricted XPC service.
protocol FinderCredentialStore: Sendable {
    func load(_ id: String) -> FinderAccess?
    func save(_ access: FinderAccess) throws
    func remove(_ id: String) throws
}

private struct DriveKeychain: FinderCredentialStore {
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.busha.r2desk.finder.keys", kSecAttrAccount as String: id]
    }
    func load(_ id: String) -> FinderAccess? {
        var query = query(id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FinderAccess.self, from: data)
    }
    func save(_ access: FinderAccess) throws {
        let data = try JSONEncoder().encode(access)
        let query = query(access.configuration.identifier)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSFileProviderError(.notAuthenticated) }
    }
    func remove(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSFileProviderError(.notAuthenticated) }
    }
}

actor FinderDrive {
    let domain: NSFileProviderDomain
    private var access: FinderAccess?
    private var catalogError: Error?
    private var catalog = FinderCatalog()
    private let catalogURL: URL
    private var requests: [String: Task<[RemoteItem], Error>] = [:]
    private var generation = UUID()
    private var writing = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private let credentialStore: any FinderCredentialStore
    private let clientFactory: @Sendable (FinderAccess) -> S3Client

    init(domain: NSFileProviderDomain, credentialStore: any FinderCredentialStore = DriveKeychain(), catalogURL: URL? = nil,
         clientFactory: @escaping @Sendable (FinderAccess) -> S3Client = {
             S3Client(connection: $0.configuration.connection, bucket: $0.configuration.bucket, credentials: $0.credentials)
         }) {
        self.domain = domain; self.credentialStore = credentialStore; self.clientFactory = clientFactory
        // Hash the domain ID: it cannot become a path outside the extension's sandbox.
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FinderCatalogs", isDirectory: true)
        self.catalogURL = catalogURL ?? folder.appendingPathComponent(S3Signer.hash(Data(domain.identifier.rawValue.utf8)) + ".json")
        if FileManager.default.fileExists(atPath: self.catalogURL.path) {
            do {
                var saved = try JSONDecoder().decode(FinderCatalog.self, from: Data(contentsOf: self.catalogURL))
                if saved.prepareForWriting() { try JSONEncoder().encode(saved).write(to: self.catalogURL, options: .atomic) }
                catalog = saved
            } catch { catalogError = NSFileProviderError(.cannotSynchronize) }
        }
        if let saved = credentialStore.load(domain.identifier.rawValue), Self.matches(saved.configuration, domain: domain) { access = saved }
    }
    private static func matches(_ config: FinderConfiguration, domain: NSFileProviderDomain) -> Bool {
        guard (try? FinderConfiguration.parse(identifier: domain.identifier.rawValue)) != nil else { return false }
        return config.identifier == domain.identifier.rawValue
    }
    func configure(_ data: Data) async throws {
        let value = try JSONDecoder().decode(FinderAccess.self, from: data)
        try value.configuration.validate()
        guard Self.matches(value.configuration, domain: domain), !value.credentials.accessKey.isEmpty, !value.credentials.secretKey.isEmpty else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let changed = access?.credentials.accessKey != value.credentials.accessKey || access?.credentials.secretKey != value.credentials.secretKey
        if changed { try credentialStore.save(value) }
        access = value
        if changed { cancelRequests() }
        if changed, let manager = NSFileProviderManager(for: domain) {
            try await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated))
        }
    }
    func revoke() throws { try credentialStore.remove(domain.identifier.rawValue); access = nil; cancelRequests() }
    func invalidate() { cancelRequests() }
    private func cancelRequests() {
        generation = UUID()
        for request in requests.values { request.cancel() }
        requests.removeAll()
    }
    private func client() throws -> S3Client {
        if let catalogError { throw catalogError }
        guard let access else { throw NSFileProviderError(.notAuthenticated) }
        return clientFactory(access)
    }
    private func persist(_ updated: FinderCatalog) throws {
        try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: catalogURL, options: .atomic)
        catalog = updated
    }
    func listing(prefix: String) async throws -> [RemoteItem] {
        await waitForWrite()
        try Task.checkCancellation()
        let client = try client()
        let revision = generation
        let task: Task<[RemoteItem], Error>
        if let pending = requests[prefix] { task = pending }
        else {
            task = Task { try await client.list(prefix: prefix, recursive: false) }
            requests[prefix] = task
        }
        do {
            let items = try await task.value
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            requests[prefix] = nil
            var updated = catalog
            try updated.replace(prefix: prefix, items: items)
            try persist(updated)
            return items
        } catch {
            if revision == generation { requests[prefix] = nil }
            throw error
        }
    }
    func item(_ id: NSFileProviderItemIdentifier) async throws -> FinderItem {
        _ = try client()
        if id == .rootContainer { return FinderItem(RemoteItem(key: "", isFolder: true), rootName: try FinderConfiguration.parse(identifier: domain.identifier.rawValue).bucket) }
        let key = try resolve(id)
        if let value = catalog.item(key: key) { return providerItem(value) }
        _ = try await listing(prefix: FinderIdentity.parent(key))
        guard let value = catalog.item(key: key) else { throw NSFileProviderError(.noSuchItem) }
        return providerItem(value)
    }
    func fetch(_ id: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion?, progress: Progress) async throws -> (URL, FinderItem) {
        let client = try client()
        let revision = generation
        let item = try await item(id)
        guard !item.remote.isFolder else { throw CocoaError(.fileReadUnsupportedScheme) }
        if let version, version.contentVersion != item.itemVersion.contentVersion { throw NSFileProviderError(.versionNoLongerAvailable) }
        guard let etag = item.remote.etag else { throw NSFileProviderError(.cannotSynchronize) }
        guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
        let folder = try manager.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try FilePaths.localURL(root: folder, relativeKey: item.filename)
        do {
            let capacity = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let capacity, capacity < item.remote.size + 512 * 1024 * 1024 { throw CocoaError(.fileWriteOutOfSpace) }
            try await client.download(key: item.remote.key, to: destination, replaceExisting: false, expectedETag: etag) { fraction in
                progress.completedUnitCount = Int64(fraction * Double(progress.totalUnitCount))
            }
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            return (destination, item)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if case StorageError.response(412, _) = error {
                _ = try? await listing(prefix: FinderIdentity.parent(item.remote.key))
                try? await manager.signalEnumerator(for: .workingSet)
                throw NSFileProviderError(.versionNoLongerAvailable)
            }
            throw error
        }
    }
    func snapshot() -> ([RemoteItem], Data) { (catalog.items, catalog.anchor) }
    func changes(since anchor: Data, prefix: String?) throws -> ([FinderCatalog.Change], Data) {
        do { return (try catalog.changes(since: anchor, prefix: prefix), catalog.anchor) }
        catch { throw NSFileProviderError(.syncAnchorExpired) }
    }
    func refresh() async throws {
        _ = try client()
        guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
        // Poll only folders already visited. No recursive bucket download is required.
        let prefixes = catalog.folders.union([""]).sorted { $0.count < $1.count }
        for prefix in prefixes {
            if !prefix.isEmpty && catalog.item(key: prefix) == nil { continue }
            _ = try await listing(prefix: prefix)
            let id: NSFileProviderItemIdentifier = prefix.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(catalog.identifier(key: prefix))
            try await manager.signalEnumerator(for: id)
        }
        try await manager.signalEnumerator(for: .workingSet)
    }
    private func resolve(_ id: NSFileProviderItemIdentifier) throws -> String {
        if id == .rootContainer { return "" }
        if let key = catalog.key(identifier: id.rawValue) { return key }
        return try FinderIdentity.key(id.rawValue)
    }
    private func providerItem(_ remote: RemoteItem) -> FinderItem {
        FinderItem(remote, identifier: catalog.identifier(key: remote.key), parentIdentifier: catalog.identifier(key: FinderIdentity.parent(remote.key)))
    }
    func enumeration(prefix: String?) async throws -> ([FinderItem], Data) {
        if let prefix { _ = try await listing(prefix: prefix) }
        let items = catalog.items.filter { prefix == nil || FinderIdentity.parent($0.key) == prefix }
        return (items.map(providerItem), catalog.anchor)
    }
    func changeItems(since anchor: Data, prefix: String?) throws -> ([NSFileProviderItemIdentifier], [FinderItem], Data) {
        let (changes, next) = try changes(since: anchor, prefix: prefix)
        return (changes.filter(\.deleted).map { NSFileProviderItemIdentifier($0.identifier) },
                changes.filter { !$0.deleted }.map { providerItem($0.item) }, next)
    }
    private func beginWrite() async throws {
        if writing { await withCheckedContinuation { writeWaiters.append($0) } }
        writing = true; cancelRequests()
        do { try Task.checkCancellation() } catch { endWrite(); throw error }
    }
    private func endWrite() {
        if !writeWaiters.isEmpty { writeWaiters.removeFirst().resume() }
        else {
            writing = false
            let readers = readWaiters; readWaiters.removeAll()
            for reader in readers { reader.resume() }
        }
    }
    private func waitForWrite() async {
        while writing { await withCheckedContinuation { readWaiters.append($0) } }
    }
    private func key(parent: NSFileProviderItemIdentifier, name: String, folder: Bool) async throws -> String {
        try FilePaths.validateName(name)
        if parent == .rootContainer { return name + (folder ? "/" : "") }
        let parentItem = try await item(parent)
        guard parentItem.remote.isFolder else { throw NSFileProviderError(.noSuchItem) }
        return parentItem.remote.key + name + (folder ? "/" : "")
    }
    private func existing(key: String, client: S3Client, except source: String? = nil) async throws -> RemoteItem? {
        let parent = FinderIdentity.parent(key)
        let name = RemoteItem(key: key, isFolder: key.hasSuffix("/")).name.precomposedStringWithCanonicalMapping.lowercased()
        return try await client.list(prefix: parent, recursive: false).first {
            $0.key != source && $0.name.precomposedStringWithCanonicalMapping.lowercased() == name
        }
    }
    private func collision(_ item: RemoteItem) -> Error {
        NSFileProviderError(.filenameCollision, userInfo: [NSFileProviderErrorItemKey: providerItem(item)])
    }
    private func signal(parents: Set<String>) async {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        for parent in parents {
            let id: NSFileProviderItemIdentifier = parent.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(catalog.identifier(key: parent))
            try? await manager.signalEnumerator(for: id)
        }
        try? await manager.signalEnumerator(for: .workingSet)
    }
    func create(template: NSFileProviderItem, contents: URL?, options: NSFileProviderCreateItemOptions, progress: Progress) async throws -> FinderItem {
        // Resolve parents before taking the write gate: a missing parent may need a network listing.
        let folder = template.contentType?.conforms(to: .folder) == true
        let destination = try await key(parent: template.parentItemIdentifier, name: template.filename, folder: folder)
        try await beginWrite(); defer { endWrite() }
        let client = try client()
        if let found = try await existing(key: destination, client: client) {
            if options.contains(.mayAlreadyExist), found.isFolder == folder {
                var identical = folder
                if !folder, let contents { identical = found.etag == (try Self.localETag(contents)) }
                if identical {
                    var updated = catalog; updated.upsert(found); try persist(updated); return providerItem(found)
                }
            }
            throw collision(found)
        }
        let created: RemoteItem
        if folder {
            try await client.createFolder(key: destination)
            created = RemoteItem(key: destination, isFolder: true)
        } else {
            guard let contents else { throw CocoaError(.fileReadUnknown) }
            let values = try contents.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            created = try await client.uploadForFinder(file: contents, key: destination) { fraction in progress.completedUnitCount = Int64(fraction * 1000) }
        }
        var updated = catalog; updated.upsert(created); try persist(updated)
        let result = providerItem(created)
        await signal(parents: [FinderIdentity.parent(destination)])
        return result
    }
    func modify(template: NSFileProviderItem, version: NSFileProviderItemVersion, fields: NSFileProviderItemFields,
                contents: URL?, progress: Progress) async throws -> FinderItem {
        let original = try await item(template.itemIdentifier)
        guard original.itemIdentifier != .rootContainer else { throw CocoaError(.fileWriteNoPermission) }
        let parent = fields.contains(.parentItemIdentifier) ? template.parentItemIdentifier : original.parentItemIdentifier
        let name = fields.contains(.filename) ? template.filename : original.filename
        let destination = try await key(parent: parent, name: name, folder: original.remote.isFolder)
        try await beginWrite(); defer { endWrite() }
        let client = try client()
        guard let currentKey = catalog.key(identifier: original.itemIdentifier.rawValue), let current = catalog.item(key: currentKey),
              providerItem(current).itemVersion.contentVersion == version.contentVersion else { throw NSFileProviderError(.versionNoLongerAvailable) }
        var result = current
        if destination != current.key {
            if let found = try await existing(key: destination, client: client, except: current.key) { throw collision(found) }
            try await client.moveForFinder(item: current, to: destination)
            var updated = catalog; try updated.move(from: current.key, to: destination); try persist(updated)
            result = catalog.item(key: destination)!
        }
        if fields.contains(.contents) {
            guard !result.isFolder, let contents, let etag = result.etag else { throw CocoaError(.fileWriteUnknown) }
            result = try await client.uploadForFinder(file: contents, key: result.key, replacingETag: etag) { fraction in progress.completedUnitCount = Int64(fraction * 1000) }
            var updated = catalog; updated.upsert(result); try persist(updated)
        }
        let item = providerItem(result)
        await signal(parents: [FinderIdentity.parent(current.key), FinderIdentity.parent(result.key)])
        return item
    }
    func delete(id: NSFileProviderItemIdentifier, version: NSFileProviderItemVersion, recursive: Bool) async throws {
        let original = try await item(id)
        guard original.itemIdentifier != .rootContainer else { throw NSFileProviderError(.deletionRejected) }
        try await beginWrite(); defer { endWrite() }
        let client = try client()
        guard let key = catalog.key(identifier: id.rawValue), let current = catalog.item(key: key),
              providerItem(current).itemVersion.contentVersion == version.contentVersion else { throw NSFileProviderError(.versionNoLongerAvailable) }
        do { try await client.deleteForFinder(item: current, recursive: recursive) }
        catch StorageError.response(404, _) {} // A retried deletion is already complete.
        var updated = catalog; updated.remove(key: key); try persist(updated)
        await signal(parents: [FinderIdentity.parent(key)])
    }
    private static func localETag(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation(); hash.update(data: block)
        }
        return "\"" + hash.finalize().map { String(format: "%02x", $0) }.joined() + "\""
    }
    static func error(_ error: Error) -> Error {
        if error is NSFileProviderError { return error }
        if case StorageError.response(let status, _) = error {
            if status == 401 || status == 403 { return NSFileProviderError(.notAuthenticated) }
            if status == 404 { return NSFileProviderError(.noSuchItem) }
        }
        if case StorageError.response(412, _) = error { return NSFileProviderError(.versionNoLongerAvailable) }
        if error is URLError { return NSFileProviderError(.serverUnreachable) }
        return error
    }
}
