import Foundation
import R2Core

struct R2CoreTests {
    func testSigningAgainstIndependentPythonFixture() throws {
        let date = ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z")!
        let request = try S3Signer.request(
            endpoint: URL(string: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")!,
            bucket: "sample-bucket", key: "folder/hello world+.txt", method: "GET",
            query: ["prefix": "folder/", "list-type": "2", "delimiter": "/"],
            credentials: Credentials(accessKey: "test-access", secretKey: "test-secret"), date: date)
        // This fixture was calculated with Python hashlib and hmac, outside the Swift signer.
        let expected = "AWS4-HMAC-SHA256 Credential=test-access/20260102/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=1f941889c6dd711489afbb2ea6461293980213fc6dc01a5961a81a5082f82bea"
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), expected)
        expectEqual(request.url?.absoluteString, "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/sample-bucket/folder/hello%20world%2B.txt?delimiter=%2F&list-type=2&prefix=folder%2F")
    }
    func testUnicodeAndLiteralPercentNamesKeepExactBytes() throws {
        expectEqual(S3Signer.encode("Файли/a+b 100%.txt", preserveSlashes: true), "%D0%A4%D0%B0%D0%B9%D0%BB%D0%B8/a%2Bb%20100%25.txt")
        expectEqual(S3Signer.encode("a//b/../c", preserveSlashes: true), "a//b/../c")
    }
    func testXMLWithEscapedNamesAndURLNames() throws {
        let xml = try S3XML.parse(Data("""
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextContinuationToken>abc+/=&amp;</NextContinuationToken>
        <Contents><Key>docs/a%26b%2B%20notes.txt</Key><LastModified>2026-01-02T03:04:05.000Z</LastModified><ETag>&quot;etag&quot;</ETag><Size>4200000000</Size></Contents>
        <CommonPrefixes><Prefix>photos%2F</Prefix></CommonPrefixes></ListBucketResult>
        """.utf8))
        expectEqual(xml.items.map(\.key), ["docs/a&b+ notes.txt", "photos/"])
        expectEqual(xml.items[0].size, 4_200_000_000)
        expectEqual(xml.items[0].etag, "\"etag\"")
        expectNotNil(xml.items[0].modified)
        expectTrue(xml.items[1].isFolder)
        expectTrue(xml.truncated)
        expectEqual(xml.nextToken, "abc+/=&")
    }
    func testXMLWithoutURLFlagDoesNotDecodeLiteralPercent() throws {
        let xml = try S3XML.parse(Data("<ListBucketResult><Contents><Key>literal%20name.txt</Key><Size>1</Size></Contents></ListBucketResult>".utf8))
        expectEqual(xml.items[0].key, "literal%20name.txt")
    }
    func testInvalidXMLFails() { expectThrows(try S3XML.parse(Data("<broken>".utf8))) }
    func testHTTP200ErrorBodyIsRecognized() throws {
        let xml = try S3XML.parse(Data("<Error><Code>PreconditionFailed</Code><Message>The source changed.</Message></Error>".utf8))
        expectEqual(xml.errorCode, "PreconditionFailed")
        expectEqual(xml.message, "The source changed.")
    }
    func testLocalPathsRejectTraversalAndAmbiguousPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/downloads")
        for key in ["../secret", "nested/../../secret", "/absolute", "folder//file", "a/./b", "", "trailing/"] {
            expectThrows(try FilePaths.localURL(root: root, relativeKey: key), key)
        }
        expectEqual(try FilePaths.localURL(root: root, relativeKey: "photos/Файл +.png").path, "/tmp/downloads/photos/Файл +.png")
    }
    func testLocalPathsRejectSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        expectThrows(try FilePaths.localURL(root: root, relativeKey: "link/secret.txt"))
    }
    func testConnectionValidation() throws {
        let valid = Connection(name: "Test", accountID: "0123456789abcdef0123456789abcdef")
        expectNoThrow(try valid.validate())
        expectEqual(valid.endpoint.host, "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")
        expectEqual(Connection(name: "EU", accountID: valid.accountID, jurisdiction: "eu").endpoint.host,
                       "0123456789abcdef0123456789abcdef.eu.r2.cloudflarestorage.com")
        for bucket in ["a", "UPPER", "-bucket", "bucket-", "a/b", "a..b", "a.-b", "a-.b", "bucket\n"] {
            expectThrows(try RemoteBucket.validateName(bucket), bucket)
        }
        expectThrows(try Connection(name: "Bad", accountID: "https://attacker").validate())
        expectThrows(try Connection(name: "Bad", accountID: valid.accountID, jurisdiction: "unknown").validate())
        expectEqual(Connection(name: "US", accountID: valid.accountID, jurisdiction: "us").endpoint.host,
                    "0123456789abcdef0123456789abcdef.us.r2.cloudflarestorage.com")
    }
    func testSavedBucketConnectionBecomesAccountConnection() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id)","name":"Saved storage","accountID":"0123456789abcdef0123456789abcdef","bucket":"old-bucket","jurisdiction":"eu"}
        """.utf8)
        let connection = try JSONDecoder().decode(Connection.self, from: data)
        try connection.validate()
        expectEqual(connection.id, id)
        expectEqual(connection.name, "Saved storage")
        expectEqual(connection.jurisdiction, "eu")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as! [String: Any]
        expectNil(encoded["bucket"])
    }
    func testBucketXMLKeepsNamesAndCreationDates() throws {
        let xml = try S3XML.parse(Data("""
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Owner><DisplayName>Not a bucket</DisplayName></Owner>
        <Buckets><Bucket><Name>photos</Name><CreationDate>2026-01-02T03:04:05.000Z</CreationDate></Bucket>
        <Bucket><Name>documents</Name><CreationDate>2026-02-02T03:04:05Z</CreationDate></Bucket></Buckets></ListAllMyBucketsResult>
        """.utf8))
        expectEqual(xml.buckets.map(\.name), ["photos", "documents"])
        expectTrue(xml.buckets.allSatisfy { $0.created != nil })
        expectTrue(xml.items.isEmpty)
    }
    func testHistoryReturnsFromFoldersToBuckets() {
        var history = BrowserHistory()
        expectEqual(history.location, .buckets)
        expectNil(history.location.parent)
        history.navigate(.folder(bucket: "photos", prefix: ""))
        history.navigate(.folder(bucket: "photos", prefix: "trip/2026/"))
        expectEqual(history.location.parent, .folder(bucket: "photos", prefix: "trip/"))
        history.back()
        expectEqual(history.location, .folder(bucket: "photos", prefix: ""))
        expectEqual(history.location.parent, .buckets)
        history.back()
        expectEqual(history.location, .buckets)
        history.forward()
        expectEqual(history.location.bucket, "photos")
        history.navigate(.folder(bucket: "documents", prefix: "work/"))
        expectTrue(!history.canGoForward)
        expectEqual(history.location.bucket, "documents")
        var otherTab = history
        otherTab.navigate(.buckets)
        expectEqual(history.location, .folder(bucket: "documents", prefix: "work/"))
        expectEqual(otherTab.location, .buckets)
    }
    func testStreamedHashMatchesKnownSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        expectEqual(try S3Signer.fileHash(url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let larger = Data(repeating: 42, count: 3 * 1024 * 1024 + 31)
        try larger.write(to: url)
        expectEqual(try S3Signer.fileHash(url), S3Signer.hash(larger))
    }

}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

struct S3ClientTests {
    private func client(bucket: String? = "test-bucket") -> S3Client {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return S3Client(connection: Connection(name: "Test", accountID: "0123456789abcdef0123456789abcdef"),
                        bucket: bucket, credentials: Credentials(accessKey: "fixture-key", secretKey: "fixture-secret"), session: URLSession(configuration: config))
    }
    func testBucketListingUsesAccountRootAndXMLPages() async throws {
        var page = 0
        MockURLProtocol.handler = { request in
            page += 1
            expectEqual(request.httpMethod, "GET")
            expectEqual(request.url?.path, "/")
            expectNotNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expectNil(query.first { $0.name == "list-type" })
            expectEqual(query.first { $0.name == "max-keys" }?.value, "1000")
            if page == 1 {
                return (200, [:], "<ListAllMyBucketsResult><Buckets><Bucket><Name>photos</Name></Bucket></Buckets><IsTruncated>true</IsTruncated><NextContinuationToken>next+/=&amp;</NextContinuationToken></ListAllMyBucketsResult>")
            }
            expectEqual(query.first { $0.name == "continuation-token" }?.value, "next+/=&")
            return (200, [:], "<ListAllMyBucketsResult><Buckets><Bucket><Name>documents</Name></Bucket><Bucket><Name>photos</Name></Bucket></Buckets></ListAllMyBucketsResult>")
        }
        let buckets = try await client(bucket: nil).listBuckets()
        expectEqual(buckets.map(\.name), ["documents", "photos"])
        expectEqual(page, 2)
    }
    func testBucketListingUsesHeaderPages() async throws {
        var page = 0
        MockURLProtocol.handler = { request in
            page += 1
            if page == 1 { return (200, ["cf-is-truncated": "true", "cf-next-continuation-token": "header+token"], "<ListAllMyBucketsResult><Buckets><Bucket><Name>photos</Name></Bucket></Buckets></ListAllMyBucketsResult>") }
            expectEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "continuation-token" }?.value, "header+token")
            return (200, ["cf-is-truncated": "false"], "<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>")
        }
        expectEqual(try await client(bucket: nil).listBuckets().map(\.name), ["photos"])
        expectEqual(page, 2)
    }
    func testBucketListingStopsOnRepeatedToken() async throws {
        var pages = 0
        MockURLProtocol.handler = { _ in
            pages += 1
            return (200, [:], "<ListAllMyBucketsResult><Buckets/><IsTruncated>true</IsTruncated><NextContinuationToken>same</NextContinuationToken></ListAllMyBucketsResult>")
        }
        do { _ = try await client(bucket: nil).listBuckets(); Issue.record("Repeated bucket token must fail") }
        catch { expectTrue(error.localizedDescription.contains("invalid bucket page")) }
        expectEqual(pages, 2)
    }
    func testBucketListingExplainsAccessPermission() async throws {
        MockURLProtocol.handler = { _ in (403, [:], "<Error><Code>AccessDenied</Code></Error>") }
        do { _ = try await client(bucket: nil).listBuckets(); Issue.record("Bucket access must fail") }
        catch { expectTrue(error.localizedDescription.contains("Admin Read only")) }
    }
    func testBucketListingRejectsWrongResponseAndUnsafeName() async throws {
        for xml in ["<ListBucketResult/>", "<ListAllMyBucketsResult><Buckets><Bucket><Name>a/b</Name></Bucket></Buckets></ListAllMyBucketsResult>"] {
            MockURLProtocol.handler = { _ in (200, [:], xml) }
            do { _ = try await client(bucket: nil).listBuckets(); Issue.record("Invalid bucket response must fail") }
            catch { expectTrue(error.localizedDescription.contains("invalid bucket")) }
        }
        MockURLProtocol.handler = { _ in (200, [:], "<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>") }
        expectTrue(try await client(bucket: nil).listBuckets().isEmpty)
    }
    func testAccountClientCannotWriteWithoutBucket() async throws {
        var requests = 0
        MockURLProtocol.handler = { _ in requests += 1; return (200, [:], "") }
        do { try await client(bucket: nil).createFolder(key: "folder/"); Issue.record("Account root must not upload") }
        catch { expectEqual(error.localizedDescription, "Open a bucket first.") }
        do { try await client(bucket: nil).delete(key: "file.txt"); Issue.record("Account root must not delete") }
        catch { expectEqual(error.localizedDescription, "Open a bucket first.") }
        expectEqual(requests, 0)
    }
    func testFileRequestsUseSelectedBucket() async throws {
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            paths.append(request.url!.path)
            return (200, [:], "<ListBucketResult/>")
        }
        _ = try await client(bucket: "photos").list(prefix: "trip/", recursive: false)
        _ = try await client(bucket: "documents").list(prefix: "work/", recursive: false)
        expectEqual(paths, ["/photos", "/documents"])
    }
    func testPaginatedListingKeepsTokenAndDeduplicatesFolders() async throws {
        var page = 0
        MockURLProtocol.handler = { request in
            page += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expectEqual(query.first { $0.name == "delimiter" }?.value, "/")
            expectNotNil(request.value(forHTTPHeaderField: "Authorization"))
            if page == 1 {
                return (200, [:], "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextContinuationToken>token+/=</NextContinuationToken><Contents><Key>folder/</Key><Size>0</Size></Contents><CommonPrefixes><Prefix>folder/</Prefix></CommonPrefixes></ListBucketResult>")
            }
            expectEqual(query.first { $0.name == "continuation-token" }?.value, "token+/=")
            return (200, [:], "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.txt</Key><Size>20</Size></Contents></ListBucketResult>")
        }
        let objects = try await client().list(prefix: "", recursive: false)
        expectEqual(page, 2)
        expectEqual(objects.map(\.key), ["folder/", "a.txt"])
    }
    func testRecursiveListingOmitsDelimiterAndCurrentFolderMarker() async throws {
        MockURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            expectNil(query.first { $0.name == "delimiter" })
            expectEqual(query.first { $0.name == "prefix" }?.value, "folder/")
            return (200, [:], "<ListBucketResult><Contents><Key>folder/</Key><Size>0</Size></Contents><Contents><Key>folder/nested/a.txt</Key><Size>1</Size></Contents></ListBucketResult>")
        }
        let objects = try await client().list(prefix: "folder/", recursive: true)
        expectEqual(objects.map(\.key), ["folder/nested/a.txt"])
    }
    func testRepeatedPageTokenFailsInsteadOfLooping() async throws {
        MockURLProtocol.handler = { _ in (200, [:], "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>same</NextContinuationToken></ListBucketResult>") }
        do { _ = try await client().list(prefix: "", recursive: false); Issue.record("The page loop was accepted.") }
        catch { expectTrue(error.localizedDescription.contains("invalid folder page")) }
    }
    func testAccessErrorsShowUsefulText() async throws {
        MockURLProtocol.handler = { _ in (403, [:], "<Error><Code>AccessDenied</Code><Message>Token does not allow this bucket.</Message></Error>") }
        do { _ = try await client().list(prefix: "", recursive: false); Issue.record("Access was granted.") }
        catch {
            expectTrue(error.localizedDescription.contains("token permissions"))
            expectTrue(error.localizedDescription.contains("Token does not allow this bucket."))
        }
    }
    func testRenameCopyErrorNeverDeletesOriginal() async throws {
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "HEAD" { return (200, ["ETag": "\"first\""], "") }
            expectEqual(request.value(forHTTPHeaderField: "cf-copy-destination-if-none-match"), "*")
            expectEqual(request.value(forHTTPHeaderField: "x-amz-copy-source-if-match"), "\"first\"")
            return (200, [:], "<Error><Code>InternalError</Code><Message>Copy failed.</Message></Error>")
        }
        do { try await client().rename(item: RemoteItem(key: "a.txt", size: 10), to: "b.txt"); Issue.record("Rename succeeded.") }
        catch { expectEqual(error.localizedDescription, "Copy failed.") }
        expectEqual(methods, ["HEAD", "PUT"])
    }
    func testRenameKeepsOriginalIfItChangedDuringCopy() async throws {
        var heads = 0; var deletes = 0
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" { heads += 1; return (200, ["ETag": heads == 1 ? "\"first\"" : "\"changed\""], "") }
            if request.httpMethod == "DELETE" { deletes += 1 }
            return (200, [:], "<CopyObjectResult><ETag>first</ETag></CopyObjectResult>")
        }
        do { try await client().rename(item: RemoteItem(key: "a.txt", size: 10), to: "b.txt"); Issue.record("Rename succeeded.") }
        catch { expectTrue(error.localizedDescription.contains("Both files were kept")) }
        expectEqual(deletes, 0)
    }
    func testRenameCopiesThenChecksThenDeletes() async throws {
        var methods: [String] = []
        MockURLProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "HEAD" { return (200, ["ETag": "\"first\""], "") }
            if request.httpMethod == "PUT" {
                expectEqual(request.value(forHTTPHeaderField: "x-amz-copy-source"), "/test-bucket/a%2B%20b.txt")
                return (200, [:], "<CopyObjectResult><ETag>first</ETag></CopyObjectResult>")
            }
            return (204, [:], "")
        }
        try await client().rename(item: RemoteItem(key: "a+ b.txt", size: 10), to: "renamed.txt")
        expectEqual(methods, ["HEAD", "PUT", "HEAD", "DELETE"])
    }
    func testCreateFolderUsesConditionalEmptyPut() async throws {
        MockURLProtocol.handler = { request in
            expectEqual(request.httpMethod, "PUT")
            expectTrue(request.url?.absoluteString.hasSuffix("/test-bucket/new/") == true)
            expectEqual(request.value(forHTTPHeaderField: "if-none-match"), "*")
            expectEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.hash(Data()))
            return (200, [:], "")
        }
        try await client().createFolder(key: "new/")
    }
    func testUploadUsesSignedPayloadAndNoOverwriteCondition() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("upload body".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var requests = 0
        MockURLProtocol.handler = { request in
            requests += 1
            expectEqual(request.httpMethod, "PUT")
            expectEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.hash(Data("upload body".utf8)))
            if requests == 1 {
                expectEqual(request.value(forHTTPHeaderField: "if-none-match"), "*")
                expectNil(request.value(forHTTPHeaderField: "if-match"))
            } else {
                expectEqual(request.value(forHTTPHeaderField: "if-match"), "\"previous\"")
                expectNil(request.value(forHTTPHeaderField: "if-none-match"))
            }
            return (200, [:], "")
        }
        let storage = client()
        try await storage.upload(file: file, key: "new.txt", replacingETag: nil, progress: { _ in })
        try await storage.upload(file: file, key: "existing.txt", replacingETag: "\"previous\"", progress: { _ in })
        expectEqual(requests, 2)
    }
    func testDownloadWritesBytesAndRequiresReplacementApproval() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("download.txt")
        MockURLProtocol.handler = { _ in (200, ["Content-Length": "13"], "download body") }
        let storage = client()
        try await storage.download(key: "remote.txt", to: file, progress: { _ in })
        expectEqual(try String(contentsOf: file), "download body")
        try Data("keep local".utf8).write(to: file)
        do {
            try await storage.download(key: "remote.txt", to: file, progress: { _ in })
            Issue.record("An existing download was replaced without consent.")
        } catch { expectTrue(error.localizedDescription.contains("already exists")) }
        expectEqual(try String(contentsOf: file), "keep local")
        try await storage.download(key: "remote.txt", to: file, replaceExisting: true, progress: { _ in })
        expectEqual(try String(contentsOf: file), "download body")
    }
    func testDownloadErrorKeepsLocalFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep local".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        MockURLProtocol.handler = { _ in (403, [:], "<Error><Code>AccessDenied</Code></Error>") }
        do {
            try await client().download(key: "remote.txt", to: file, replaceExisting: true, progress: { _ in })
            Issue.record("An error response was saved as a file.")
        } catch { expectTrue(error.localizedDescription.contains("refused access")) }
        expectEqual(try String(contentsOf: file), "keep local")
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) { if actual != expected { Issue.record("Expected \(expected), got \(actual)") } }
private func expectTrue(_ value: Bool) { if !value { Issue.record("Expected true") } }
private func expectNotNil<T>(_ value: T?) { if value == nil { Issue.record("Expected a non-nil value") } }
private func expectNil<T>(_ value: T?) { if value != nil { Issue.record("Expected nil") } }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, _ detail: String = "") {
    do { _ = try expression(); Issue.record("Expected an error. \(detail)") } catch {}
}
private func expectNoThrow<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression() } catch { Issue.record("Unexpected error: \(error)") }
}

private final class Results: @unchecked Sendable {
    static let shared = Results()
    private let lock = NSLock()
    private var failures: [String] = []
    func record(_ text: String) { lock.lock(); failures.append(text); print("FAIL: " + text); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return failures.count }
}
private enum Issue { static func record(_ text: String) { Results.shared.record(text) } }

@main struct CheckRunner {
    static func main() async {
        let core = R2CoreTests()
        let s3 = S3ClientTests()
        let checks: [(String, () async throws -> Void)] = [
            ("testSigningAgainstIndependentPythonFixture", { try core.testSigningAgainstIndependentPythonFixture() }),
            ("testUnicodeAndLiteralPercentNamesKeepExactBytes", { try core.testUnicodeAndLiteralPercentNamesKeepExactBytes() }),
            ("testXMLWithEscapedNamesAndURLNames", { try core.testXMLWithEscapedNamesAndURLNames() }),
            ("testXMLWithoutURLFlagDoesNotDecodeLiteralPercent", { try core.testXMLWithoutURLFlagDoesNotDecodeLiteralPercent() }),
            ("testInvalidXMLFails", { core.testInvalidXMLFails() }),
            ("testHTTP200ErrorBodyIsRecognized", { try core.testHTTP200ErrorBodyIsRecognized() }),
            ("testLocalPathsRejectTraversalAndAmbiguousPaths", { try core.testLocalPathsRejectTraversalAndAmbiguousPaths() }),
            ("testLocalPathsRejectSymbolicLinks", { try core.testLocalPathsRejectSymbolicLinks() }),
            ("testConnectionValidation", { try core.testConnectionValidation() }),
            ("testSavedBucketConnectionBecomesAccountConnection", { try core.testSavedBucketConnectionBecomesAccountConnection() }),
            ("testBucketXMLKeepsNamesAndCreationDates", { try core.testBucketXMLKeepsNamesAndCreationDates() }),
            ("testHistoryReturnsFromFoldersToBuckets", { core.testHistoryReturnsFromFoldersToBuckets() }),
            ("testBucketListingUsesAccountRootAndXMLPages", { try await s3.testBucketListingUsesAccountRootAndXMLPages() }),
            ("testBucketListingUsesHeaderPages", { try await s3.testBucketListingUsesHeaderPages() }),
            ("testBucketListingStopsOnRepeatedToken", { try await s3.testBucketListingStopsOnRepeatedToken() }),
            ("testBucketListingExplainsAccessPermission", { try await s3.testBucketListingExplainsAccessPermission() }),
            ("testBucketListingRejectsWrongResponseAndUnsafeName", { try await s3.testBucketListingRejectsWrongResponseAndUnsafeName() }),
            ("testAccountClientCannotWriteWithoutBucket", { try await s3.testAccountClientCannotWriteWithoutBucket() }),
            ("testFileRequestsUseSelectedBucket", { try await s3.testFileRequestsUseSelectedBucket() }),
            ("testStreamedHashMatchesKnownSHA256", { try core.testStreamedHashMatchesKnownSHA256() }),
            ("testPaginatedListingKeepsTokenAndDeduplicatesFolders", { try await s3.testPaginatedListingKeepsTokenAndDeduplicatesFolders() }),
            ("testRecursiveListingOmitsDelimiterAndCurrentFolderMarker", { try await s3.testRecursiveListingOmitsDelimiterAndCurrentFolderMarker() }),
            ("testRepeatedPageTokenFailsInsteadOfLooping", { try await s3.testRepeatedPageTokenFailsInsteadOfLooping() }),
            ("testAccessErrorsShowUsefulText", { try await s3.testAccessErrorsShowUsefulText() }),
            ("testRenameCopyErrorNeverDeletesOriginal", { try await s3.testRenameCopyErrorNeverDeletesOriginal() }),
            ("testRenameKeepsOriginalIfItChangedDuringCopy", { try await s3.testRenameKeepsOriginalIfItChangedDuringCopy() }),
            ("testRenameCopiesThenChecksThenDeletes", { try await s3.testRenameCopiesThenChecksThenDeletes() }),
            ("testCreateFolderUsesConditionalEmptyPut", { try await s3.testCreateFolderUsesConditionalEmptyPut() }),
            ("testUploadUsesSignedPayloadAndNoOverwriteCondition", { try await s3.testUploadUsesSignedPayloadAndNoOverwriteCondition() }),
            ("testDownloadWritesBytesAndRequiresReplacementApproval", { try await s3.testDownloadWritesBytesAndRequiresReplacementApproval() }),
            ("testDownloadErrorKeepsLocalFile", { try await s3.testDownloadErrorKeepsLocalFile() }),
        ]
        for (name, check) in checks {
            let before = Results.shared.count
            do { try await check() } catch { Issue.record("Unexpected error in \(name): \(error)") }
            if Results.shared.count == before { print("PASS: " + name) }
        }
        print("\(checks.count) checks, \(Results.shared.count) failures")
        if Results.shared.count > 0 { exit(1) }
    }
}
