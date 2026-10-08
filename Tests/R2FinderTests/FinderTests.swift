import FileProvider
import R2Core
import R2FinderShared
@testable import R2FileProvider

final class FinderTests {
    func testDomainsBindToAccountLocationAndBucket() throws {
        let connection = Connection(name: "Example", accountID: String(repeating: "a", count: 32))
        let config = FinderConfiguration(connection: connection, bucket: "test.bucket")
        let parsed = try FinderConfiguration.parse(identifier: config.identifier)
        expectEqual(parsed.connection.id, connection.id)
        expectEqual(parsed.connection.endpoint, connection.endpoint)
        expectEqual(parsed.bucket, config.bucket)
        var other = connection; other.accountID = String(repeating: "b", count: 32)
        expectDifferent(FinderIdentity.domain(connection: other, bucket: config.bucket), config.identifier)
        other = connection; other.jurisdiction = "eu"
        expectDifferent(FinderIdentity.domain(connection: other, bucket: config.bucket), config.identifier)
        expectThrows(try FinderConfiguration.parse(identifier: "r2desk.invalid"))
        expectThrows(try FinderConfiguration.parse(identifier: config.identifier + "/../bad"))
    }
    func testItemIDsKeepExactNamesAndRejectUnsafePaths() throws {
        for key in ["photos/Файл + 100%.jpg", "folder/", "e\u{301}.txt", "é.txt"] {
            expectEqual(try FinderIdentity.key(FinderIdentity.item(key)), key)
        }
        expectDifferent(FinderIdentity.item("e\u{301}.txt"), FinderIdentity.item("é.txt"))
        expectEqual(FinderIdentity.parent("a/b/"), "a/")
        for key in ["", "/root", "a//b", "../file", "a/./file", "a/../../file", "a\0b"] {
            expectThrows(try FinderIdentity.key(FinderIdentity.item(key)), key)
        }
    }
    func testCatalogRestartsAndReportsUpdatesAndSubtreeDeletion() throws {
        var catalog = FinderCatalog()
        try catalog.replace(prefix: "", items: [RemoteItem(key: "folder/", isFolder: true)])
        try catalog.replace(prefix: "folder/", items: [RemoteItem(key: "folder/a.txt", size: 1, etag: "first")])
        let anchor = catalog.anchor
        catalog = try JSONDecoder().decode(FinderCatalog.self, from: JSONEncoder().encode(catalog))
        try catalog.replace(prefix: "folder/", items: [RemoteItem(key: "folder/a.txt", size: 2, etag: "next")])
        expectEqual(try catalog.changes(since: anchor).first?.item.etag, "next")
        try catalog.replace(prefix: "", items: [])
        expectTrue(catalog.items.isEmpty)
        expectFalse(catalog.folders.contains("folder/"))
        let changes = try catalog.changes(since: anchor)
        expectEqual(Set(changes.map { $0.item.key }), ["folder/", "folder/a.txt"])
        expectTrue(changes.allSatisfy(\.deleted))
    }
    func testCatalogRejectsNamesFinderCannotRepresentWithoutChangingState() throws {
        var catalog = FinderCatalog()
        try catalog.replace(prefix: "", items: [RemoteItem(key: "safe.txt")])
        let anchor = catalog.anchor
        for items in [[RemoteItem(key: "a"), RemoteItem(key: "a/", isFolder: true)],
                      [RemoteItem(key: "A.txt"), RemoteItem(key: "a.txt")],
                      [RemoteItem(key: "é"), RemoteItem(key: "e\u{301}")],
                      [RemoteItem(key: "../bad")], [RemoteItem(key: "other/file")]] {
            expectThrows(try catalog.replace(prefix: "", items: items))
            expectEqual(catalog.anchor, anchor)
            expectEqual(catalog.items.map(\.key), ["safe.txt"])
        }
    }
    func testCatalogExpiresOldOrForeignAnchorsAndFiltersFolderChanges() throws {
        var catalog = FinderCatalog()
        let initial = catalog.anchor
        try catalog.replace(prefix: "", items: [RemoteItem(key: "a/", isFolder: true), RemoteItem(key: "b/", isFolder: true)])
        try catalog.replace(prefix: "a/", items: [RemoteItem(key: "a/file")])
        try catalog.replace(prefix: "b/", items: [RemoteItem(key: "b/file")])
        expectEqual(try catalog.changes(since: initial, prefix: "a/").map { $0.item.key }, ["a/file"])
        expectThrows(try catalog.changes(since: FinderCatalog().anchor))
        for number in 0..<2001 { try catalog.replace(prefix: "a/", items: [RemoteItem(key: "a/file", size: Int64(number))]) }
        expectThrows(try catalog.changes(since: initial))
        expectTrue(try catalog.changes(since: catalog.anchor).isEmpty)
    }
    func testWritableCapabilitiesAndPrincipalClass() {
        expectNotNil(NSClassFromString("R2DeskFileProviderExtension"))
        let item = FinderItem(RemoteItem(key: "file.txt", size: 30, etag: "etag"))
        expectTrue(item.capabilities.contains(.allowsReading))
        expectTrue(item.capabilities.contains(.allowsWriting))
        expectTrue(item.capabilities.contains(.allowsDeleting))
        expectTrue(item.capabilities.contains(.allowsRenaming))
        let folder = FinderItem(RemoteItem(key: "folder/", isFolder: true))
        expectTrue(folder.capabilities.contains(.allowsContentEnumerating))
        expectTrue(folder.capabilities.contains(.allowsAddingSubItems))
    }
    func testExtensionRequiresCredentialsForWrites() async throws {
        let config = configuration()
        let provider = FileProviderExtension(domain: domain(config))
        let item = FinderItem(RemoteItem(key: "file.txt"))
        let request = NSFileProviderRequest()
        let create: Error? = await withCheckedContinuation { reply in
            _ = provider.createItem(basedOn: item, fields: [], contents: nil, options: [], request: request) { _, _, _, error in reply.resume(returning: error) }
        }
        expectEqual((create as NSError?)?.code, NSFileProviderError.Code.notAuthenticated.rawValue)
        let modify: Error? = await withCheckedContinuation { reply in
            _ = provider.modifyItem(item, baseVersion: item.itemVersion, changedFields: .contents, contents: nil, options: [], request: request) { _, _, _, error in reply.resume(returning: error) }
        }
        expectEqual((modify as NSError?)?.code, NSFileProviderError.Code.notAuthenticated.rawValue)
        let delete: Error? = await withCheckedContinuation { reply in
            _ = provider.deleteItem(identifier: item.itemIdentifier, baseVersion: item.itemVersion, options: [], request: request) { error in reply.resume(returning: error) }
        }
        expectEqual((delete as NSError?)?.code, NSFileProviderError.Code.notAuthenticated.rawValue)
        provider.invalidate()
    }
    func testDrivePersistsMetadataAndRejectsWrongBucketCredentials() async throws {
        let config = configuration()
        let store = MemoryKeys(access: access(config))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let index = folder.appendingPathComponent("catalog.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = session()
        HTTPStub.handler = { request in
            expectEqual(request.httpMethod, "GET")
            return (200, [:], "<ListBucketResult><Contents><Key>a.txt</Key><Size>3</Size><ETag>&quot;first&quot;</ETag></Contents></ListBucketResult>")
        }
        let factory: @Sendable (FinderAccess) -> S3Client = { S3Client(connection: $0.configuration.connection, bucket: $0.configuration.bucket, credentials: $0.credentials, session: session) }
        let drive = FinderDrive(domain: domain(config), credentialStore: store, catalogURL: index, clientFactory: factory)
        let items = try await drive.listing(prefix: "")
        expectEqual(items.map(\.key), ["a.txt"])
        let saved = try String(contentsOf: index)
        expectFalse(saved.contains(store.access!.credentials.secretKey))
        expectFalse(saved.contains(store.access!.credentials.accessKey))
        let restarted = FinderDrive(domain: domain(config), credentialStore: store, catalogURL: index, clientFactory: factory)
        let savedItems = await restarted.snapshot().0
        expectEqual(savedItems.map(\.key), ["a.txt"])
        let wrong = FinderConfiguration(connection: config.connection, bucket: "other-bucket")
        do { try await drive.configure(JSONEncoder().encode(access(wrong))); fail("Wrong bucket was accepted") }
        catch { expectEqual((error as NSError).code, NSFileProviderError.Code.notAuthenticated.rawValue) }
        try await drive.revoke()
        expectNil(store.access)
        do { _ = try await drive.listing(prefix: ""); fail("Revoked keys were used") }
        catch { expectEqual((error as NSError).code, NSFileProviderError.Code.notAuthenticated.rawValue) }
    }
    func testMovesKeepItemIDsAndOldCatalogsKeepDownloadedIDs() throws {
        var catalog = FinderCatalog()
        try catalog.replace(prefix: "", items: [RemoteItem(key: "old/", isFolder: true)])
        try catalog.replace(prefix: "old/", items: [RemoteItem(key: "old/file.txt", etag: "first")])
        let folderID = catalog.identifier(key: "old/")
        let fileID = catalog.identifier(key: "old/file.txt")
        let anchor = catalog.anchor
        try catalog.move(from: "old/", to: "new/")
        expectEqual(catalog.identifier(key: "new/"), folderID)
        expectEqual(catalog.identifier(key: "new/file.txt"), fileID)
        expectEqual(catalog.key(identifier: fileID), "new/file.txt")
        expectEqual(try catalog.changes(since: anchor, prefix: "old/").first?.identifier, fileID)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as! [String: Any]
        json.removeValue(forKey: "identifiers"); json.removeValue(forKey: "capabilitiesVersion")
        var legacy = try JSONDecoder().decode(FinderCatalog.self, from: JSONSerialization.data(withJSONObject: json))
        expectEqual(legacy.identifier(key: "new/file.txt"), FinderIdentity.item("new/file.txt"))
        let legacyAnchor = legacy.anchor
        expectTrue(legacy.prepareForWriting())
        expectFalse(legacy.prepareForWriting())
        expectEqual(try legacy.changes(since: legacyAnchor).count, 2)
    }
    func testDamagedCatalogDoesNotDiscardStableIDsOrUseNetwork() async throws {
        let config = configuration(), store = MemoryKeys(access: nil)
        store.save(access(config))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = folder.appendingPathComponent("catalog.json"), damaged = Data("incomplete catalog".utf8)
        try damaged.write(to: index)
        let session = session()
        HTTPStub.handler = { _ in fail("Damaged catalog used the network"); return (500, [:], "") }
        let drive = FinderDrive(domain: domain(config), credentialStore: store, catalogURL: index,
            clientFactory: { S3Client(connection: $0.configuration.connection, bucket: $0.configuration.bucket, credentials: $0.credentials, session: session) })
        do { _ = try await drive.listing(prefix: ""); fail("Damaged catalog was replaced") }
        catch { expectEqual((error as NSError).code, NSFileProviderError.Code.cannotSynchronize.rawValue) }
        expectEqual(try Data(contentsOf: index), damaged)
    }
    func testUploadMetadataRejectsAnotherWritersVersion() async throws {
        let config = configuration(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input.txt")
        try Data("abc".utf8).write(to: file)
        let client = S3Client(connection: config.connection, bucket: config.bucket, credentials: access(config).credentials, session: session())
        HTTPStub.handler = { request in
            if request.httpMethod == "PUT" { return (200, ["ETag": "\"uploaded\""], "") }
            expectEqual(request.httpMethod, "HEAD")
            expectEqual(request.value(forHTTPHeaderField: "If-Match"), "\"uploaded\"")
            return (412, [:], "")
        }
        do { _ = try await client.uploadForFinder(file: file, key: "file.txt"); fail("Upload returned another writer's metadata") }
        catch { if case StorageError.response(412, _) = error {} else { fail("Wrong upload conflict error") } }
    }
    func testUploadRenameEditAndDeleteWithMockR2() async throws {
        let fixture = RemoteFixture()
        HTTPStub.handler = { fixture.response($0) }
        let config = configuration(), store = MemoryKeys(access: nil)
        store.save(access(config))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input.txt"); try Data("abc".utf8).write(to: file)
        let session = session()
        let drive = FinderDrive(domain: domain(config), credentialStore: store, catalogURL: folder.appendingPathComponent("catalog.json"), clientFactory: {
            S3Client(connection: $0.configuration.connection, bucket: $0.configuration.bucket, credentials: $0.credentials, session: session)
        })
        let created = try await drive.create(template: FinderItem(RemoteItem(key: "new.txt")), contents: file, options: [], progress: Progress(totalUnitCount: 1000))
        expectEqual(created.filename, "new.txt")
        let originalID = created.itemIdentifier
        let renamed = try await drive.modify(template: FinderItem(RemoteItem(key: "renamed.txt"), identifier: originalID.rawValue),
                                              version: created.itemVersion, fields: .filename, contents: nil, progress: Progress())
        expectEqual(renamed.itemIdentifier, originalID)
        expectEqual(renamed.remote.key, "renamed.txt")
        expectNil(fixture.objects["new.txt"])
        expectNotNil(fixture.objects["renamed.txt"])
        let edited = try await drive.modify(template: renamed, version: renamed.itemVersion, fields: .contents, contents: file, progress: Progress(totalUnitCount: 1000))
        expectEqual(edited.itemIdentifier, originalID)
        expectDifferent(edited.remote.etag, renamed.remote.etag)
        try await drive.delete(id: edited.itemIdentifier, version: edited.itemVersion, recursive: false)
        expectNil(fixture.objects["renamed.txt"])
        let snapshot = await drive.snapshot()
        expectTrue(snapshot.0.isEmpty)
        expectTrue(fixture.conditionalWrites >= 1)
        expectTrue(fixture.conditionalHeads >= 3)
    }
    func testChangedFileAndNameCollisionNeverOverwrite() async throws {
        let fixture = RemoteFixture()
        fixture.objects = ["file.txt": .init(etag: "\"first\"", size: 3)]
        HTTPStub.handler = { fixture.response($0) }
        let config = configuration(), store = MemoryKeys(access: access(configuration()))
        store.save(access(config))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("input"); try Data("abc".utf8).write(to: file)
        let session = session()
        let drive = FinderDrive(domain: domain(config), credentialStore: store, catalogURL: folder.appendingPathComponent("catalog.json"), clientFactory: {
            S3Client(connection: $0.configuration.connection, bucket: $0.configuration.bucket, credentials: $0.credentials, session: session)
        })
        _ = try await drive.listing(prefix: "")
        let (listed, _) = try await drive.enumeration(prefix: nil)
        let item = listed[0]
        fixture.objects["file.txt"] = .init(etag: "\"changed\"", size: 3)
        do {
            _ = try await drive.modify(template: item, version: item.itemVersion, fields: .contents, contents: file, progress: Progress())
            fail("A changed file was overwritten")
        } catch {}
        expectEqual(fixture.objects["file.txt"]?.etag, "\"changed\"")
        do {
            _ = try await drive.create(template: FinderItem(RemoteItem(key: "FILE.txt")), contents: file, options: [], progress: Progress())
            fail("A name collision was accepted")
        } catch { expectEqual((error as NSError).code, NSFileProviderError.Code.filenameCollision.rawValue) }
        expectNil(fixture.objects["FILE.txt"])
        expectEqual(fixture.deletions.count, 0)
    }
    func testFolderCopyFailureKeepsEverySourceAndSuccessfulMoveKeepsIDs() async throws {
        let fixture = RemoteFixture()
        fixture.objects = ["old/": .init(etag: "\"marker\"", size: 0), "old/a.txt": .init(etag: "\"a\"", size: 3)]
        fixture.failCopies = true
        HTTPStub.handler = { fixture.response($0) }
        let config = configuration()
        let client = S3Client(connection: config.connection, bucket: config.bucket, credentials: access(config).credentials, session: session())
        do { try await client.moveForFinder(item: RemoteItem(key: "old/", isFolder: true), to: "failed/"); fail("Failed copy succeeded") }
        catch {}
        expectNotNil(fixture.objects["old/"]); expectNotNil(fixture.objects["old/a.txt"])
        expectTrue(fixture.deletions.isEmpty)
        fixture.failCopies = false
        let store = MemoryKeys(access: access(config))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = session()
        let drive = FinderDrive(domain: domain(config), credentialStore: store, catalogURL: folder.appendingPathComponent("catalog.json"), clientFactory: {
            S3Client(connection: $0.configuration.connection, bucket: $0.configuration.bucket, credentials: $0.credentials, session: session)
        })
        _ = try await drive.listing(prefix: ""); _ = try await drive.listing(prefix: "old/")
        let (roots, _) = try await drive.enumeration(prefix: nil)
        let old = roots.first { $0.remote.key == "old/" }!
        let child = roots.first { $0.remote.key == "old/a.txt" }!
        let moved = try await drive.modify(template: FinderItem(RemoteItem(key: "new/", isFolder: true), identifier: old.itemIdentifier.rawValue),
                                            version: old.itemVersion, fields: .filename, contents: nil, progress: Progress())
        expectEqual(moved.itemIdentifier, old.itemIdentifier)
        let movedChild = try await drive.item(child.itemIdentifier)
        expectEqual(movedChild.remote.key, "new/a.txt")
        expectEqual(movedChild.parentItemIdentifier, old.itemIdentifier)
        expectNil(fixture.objects["old/a.txt"]); expectNotNil(fixture.objects["new/a.txt"])
    }
    private func configuration() -> FinderConfiguration {
        FinderConfiguration(connection: Connection(name: "Test", accountID: String(repeating: "a", count: 32)), bucket: "test-bucket")
    }
    private func domain(_ config: FinderConfiguration) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(config.identifier), displayName: "Test")
    }
    private func access(_ config: FinderConfiguration) -> FinderAccess {
        // Random test values. No real access keys are used or saved.
        FinderAccess(configuration: config, credentials: Credentials(accessKey: UUID().uuidString, secretKey: UUID().uuidString))
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: configuration)
    }
}

private final class MemoryKeys: FinderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: FinderAccess?
    var access: FinderAccess? { lock.lock(); defer { lock.unlock() }; return value }
    init(access: FinderAccess?) { value = access }
    func load(_ id: String) -> FinderAccess? { access }
    func save(_ access: FinderAccess) { lock.lock(); defer { lock.unlock() }; value = access }
    func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; value = nil }
}

private final class HTTPStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum CheckResults {
    static var failures = 0
}
private func fail(_ message: String) { CheckResults.failures += 1; print("FAIL: " + message) }
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) { if actual != expected { fail("Values differ") } }
private func expectDifferent<T: Equatable>(_ actual: T, _ expected: T) { if actual == expected { fail("Values must differ") } }
private func expectTrue(_ value: Bool) { if !value { fail("Expected true") } }
private func expectFalse(_ value: Bool) { if value { fail("Expected false") } }
private func expectNil<T>(_ value: T?) { if value != nil { fail("Expected nil") } }
private func expectNotNil<T>(_ value: T?) { if value == nil { fail("Expected a value") } }
private func expectThrows<T>(_ body: @autoclosure () throws -> T, _ message: String = "") {
    do { _ = try body(); fail("Expected an error. " + message) } catch {}
}

@main
struct FinderChecks {
    static func main() async {
        let suite = FinderTests()
        let checks: [(String, () async throws -> Void)] = [
            ("Domain identity", { try suite.testDomainsBindToAccountLocationAndBucket() }),
            ("Safe paths and exact names", { try suite.testItemIDsKeepExactNamesAndRejectUnsafePaths() }),
            ("Durable changes and folder deletion", { try suite.testCatalogRestartsAndReportsUpdatesAndSubtreeDeletion() }),
            ("Finder name collisions", { try suite.testCatalogRejectsNamesFinderCannotRepresentWithoutChangingState() }),
            ("Expired anchors and folder scope", { try suite.testCatalogExpiresOldOrForeignAnchorsAndFiltersFolderChanges() }),
            ("Writable capabilities and principal class", { suite.testWritableCapabilitiesAndPrincipalClass() }),
            ("Writes require credentials", { try await suite.testExtensionRequiresCredentialsForWrites() }),
            ("Stable IDs and read-only catalog migration", { try suite.testMovesKeepItemIDsAndOldCatalogsKeepDownloadedIDs() }),
            ("Mock upload, rename, edit, and delete", { try await suite.testUploadRenameEditAndDeleteWithMockR2() }),
            ("Changed files and name collisions", { try await suite.testChangedFileAndNameCollisionNeverOverwrite() }),
            ("Folder copy failure and stable IDs", { try await suite.testFolderCopyFailureKeepsEverySourceAndSuccessfulMoveKeepsIDs() }),
            ("Metadata persistence and credential binding", { try await suite.testDrivePersistsMetadataAndRejectsWrongBucketCredentials() }),
            ("Damaged catalog preserves stable IDs", { try await suite.testDamagedCatalogDoesNotDiscardStableIDsOrUseNetwork() }),
            ("Upload metadata version conflict", { try await suite.testUploadMetadataRejectsAnotherWritersVersion() })
        ]
        for (name, check) in checks {
            let before = CheckResults.failures
            do { try await check() } catch { fail("Unexpected error in " + name) }
            if before == CheckResults.failures { print("PASS: " + name) }
        }
        print("\(checks.count) Finder checks, \(CheckResults.failures) failures")
        if CheckResults.failures > 0 { exit(1) }
    }
}

private final class RemoteFixture: @unchecked Sendable {
    struct Object { let etag: String; let size: Int }
    var objects: [String: Object] = [:]
    var deletions: [String] = []
    var failCopies = false
    var conditionalWrites = 0
    var conditionalHeads = 0
    private var uploads = 0
    func response(_ request: URLRequest) -> (Int, [String: String], String) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let key = request.url!.path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
        switch request.httpMethod {
        case "GET":
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let prefix = query["prefix"] ?? ""
            var prefixes = Set<String>(), rows = ""
            for (name, object) in objects.sorted(by: { $0.key < $1.key }) where name.hasPrefix(prefix) {
                let remainder = String(name.dropFirst(prefix.count))
                if query["delimiter"] == "/", let slash = remainder.firstIndex(of: "/"), remainder.index(after: slash) != remainder.endIndex {
                    prefixes.insert(prefix + remainder[...slash]); continue
                }
                if query["delimiter"] == "/", name.hasSuffix("/"), name != prefix { prefixes.insert(name); continue }
                rows += "<Contents><Key>" + S3Signer.encode(name, preserveSlashes: true) + "</Key><Size>\(object.size)</Size><ETag>" + object.etag.replacingOccurrences(of: "\"", with: "&quot;") + "</ETag><LastModified>2026-01-02T03:04:05Z</LastModified></Contents>"
            }
            for prefix in prefixes.sorted() { rows += "<CommonPrefixes><Prefix>" + S3Signer.encode(prefix, preserveSlashes: true) + "</Prefix></CommonPrefixes>" }
            return (200, [:], "<ListBucketResult><EncodingType>url</EncodingType>" + rows + "</ListBucketResult>")
        case "HEAD":
            guard let object = objects[key] else { return (404, [:], "") }
            if let expected = request.value(forHTTPHeaderField: "If-Match") {
                conditionalHeads += 1
                guard expected == object.etag else { return (412, [:], "") }
            }
            return (200, ["ETag": object.etag, "Content-Length": String(object.size), "Last-Modified": "Fri, 02 Jan 2026 03:04:05 GMT"], "")
        case "PUT":
            if let source = request.value(forHTTPHeaderField: "x-amz-copy-source") {
                if failCopies { return (500, [:], "<Error><Code>InternalError</Code></Error>") }
                let decoded = source.removingPercentEncoding!
                let name = decoded.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
                guard let object = objects[name] else { return (404, [:], "") }
                guard request.value(forHTTPHeaderField: "x-amz-copy-source-if-match") == object.etag, objects[key] == nil else { return (412, [:], "") }
                expectEqual(request.value(forHTTPHeaderField: "cf-copy-destination-if-none-match"), "*")
                objects[key] = object
                return (200, [:], "<CopyObjectResult><ETag>" + object.etag.replacingOccurrences(of: "\"", with: "&quot;") + "</ETag></CopyObjectResult>")
            }
            if let expected = request.value(forHTTPHeaderField: "If-Match") {
                conditionalWrites += 1
                guard objects[key]?.etag == expected else { return (412, [:], "") }
            } else {
                expectEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                guard objects[key] == nil else { return (412, [:], "") }
            }
            uploads += 1
            objects[key] = Object(etag: "\"upload-\(uploads)\"", size: key.hasSuffix("/") ? 0 : 3)
            return (200, ["ETag": objects[key]!.etag], "")
        case "DELETE":
            deletions.append(key); objects.removeValue(forKey: key); return (204, [:], "")
        default: fail("Unexpected request method"); return (500, [:], "")
        }
    }
}
