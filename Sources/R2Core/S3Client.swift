import Foundation
import UniformTypeIdentifiers

private final class TransferDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: TransferProgress
    init(_ progress: @escaping TransferProgress) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public struct S3Client: StorageService {
    public let connection: Connection
    public let bucket: String?
    private let credentials: Credentials
    private let session: URLSession
    public init(connection: Connection, bucket: String? = nil, credentials: Credentials, session: URLSession? = nil) {
        self.connection = connection; self.bucket = bucket; self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }

    private func request(_ method: String, key: String = "", query: [String: String] = [:],
                         headers: [String: String] = [:], hash: String = S3Signer.hash(Data())) throws -> URLRequest {
        guard let bucket else { throw StorageError.message("Open a bucket first.") }
        try RemoteBucket.validateName(bucket)
        return try S3Signer.request(endpoint: connection.endpoint, bucket: bucket, key: key, method: method,
                             query: query, headers: headers, payloadHash: hash, credentials: credentials)
    }

    public func listBuckets() async throws -> [RemoteBucket] {
        try connection.validate()
        var buckets: [String: RemoteBucket] = [:]
        var token: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var query = ["max-keys": "1000"]
            if let token { query["continuation-token"] = token }
            let request = try S3Signer.request(endpoint: connection.endpoint, bucket: "", method: "GET",
                                              query: query, credentials: credentials)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, [401, 403].contains(http.statusCode) {
                throw StorageError.message("R2 refused the bucket list. Use S3 keys with Admin Read only or Admin Read & Write access to this account.")
            }
            let http = try validate(response, data: data)
            let xml = try S3XML.parse(data)
            guard xml.rootElement == "ListAllMyBucketsResult" else {
                throw StorageError.message("R2 returned an invalid bucket list.")
            }
            for bucket in xml.buckets {
                try RemoteBucket.validateName(bucket.name)
                buckets[bucket.name] = bucket
            }
            let truncated = http.value(forHTTPHeaderField: "cf-is-truncated").map { $0 == "true" } ?? xml.truncated
            if truncated {
                guard let next = http.value(forHTTPHeaderField: "cf-next-continuation-token") ?? xml.nextToken,
                      !next.isEmpty, seen.insert(next).inserted else {
                    throw StorageError.message("R2 returned an invalid bucket page. Refresh the bucket list.")
                }
                token = next
            } else { token = nil }
        } while token != nil
        return buckets.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func validate(_ response: URLResponse, data: Data = Data()) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw StorageError.message("R2 returned no HTTP response.") }
        guard (200...299).contains(response.statusCode) else {
            let xml = try? S3XML.parse(data)
            throw StorageError.response(response.statusCode, xml?.message ?? xml?.errorCode ?? "")
        }
        // CopyObject can return HTTP 200 with an Error XML body.
        if !data.isEmpty, let xml = try? S3XML.parse(data), let code = xml.errorCode {
            throw StorageError.message(xml.message ?? code)
        }
        return response
    }

    public func list(prefix: String, recursive: Bool = false) async throws -> [RemoteItem] {
        var result: [RemoteItem] = []
        var token: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            var query = ["list-type": "2", "prefix": prefix, "max-keys": "1000", "encoding-type": "url"]
            if !recursive { query["delimiter"] = "/" }
            if let token { query["continuation-token"] = token }
            let (data, response) = try await session.data(for: request("GET", query: query))
            _ = try validate(response, data: data)
            let xml = try S3XML.parse(data)
            result += xml.items.filter { $0.key != prefix }
            if xml.truncated {
                guard let next = xml.nextToken, seen.insert(next).inserted else {
                    throw StorageError.message("R2 returned an invalid folder page. Refresh the folder.")
                }
                token = next
            } else { token = nil }
        } while token != nil
        // A folder marker and a common prefix can refer to the same folder.
        var unique: [String: RemoteItem] = [:]
        for item in result { unique[item.key] = item }
        return unique.values.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func upload(file: URL, key: String, replacingETag: String? = nil,
                       progress: @escaping TransferProgress = { _ in }) async throws {
        _ = try await uploadResult(file: file, key: key, replacingETag: replacingETag, progress: progress)
    }

    private func uploadResult(file: URL, key: String, replacingETag: String?, progress: @escaping TransferProgress) async throws -> String? {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5 * 1024 * 1024 * 1024 else {
            throw StorageError.message("This version can upload files up to 5 GiB. Select a smaller file.")
        }
        // Hash in small blocks on a background task. Cancel the hash when the transfer is cancelled.
        let hashTask = Task.detached { try S3Signer.fileHash(file) }
        let hash = try await withTaskCancellationHandler(operation: { try await hashTask.value }, onCancel: { hashTask.cancel() })
        try Task.checkCancellation()
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var headers = ["content-type": mime]
        if let etag = replacingETag { headers["if-match"] = etag }
        else { headers["if-none-match"] = "*" }
        let request = try request("PUT", key: key, headers: headers, hash: hash)
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: TransferDelegate(progress))
        let http = try validate(response, data: data)
        progress(1)
        return http.value(forHTTPHeaderField: "ETag")
    }

    public func uploadForFinder(file: URL, key: String, replacingETag: String? = nil, progress: @escaping TransferProgress = { _ in }) async throws -> RemoteItem {
        guard let etag = try await uploadResult(file: file, key: key, replacingETag: replacingETag, progress: progress) else {
            throw StorageError.message("R2 returned no upload checksum. Refresh the Finder drive.")
        }
        return try await metadata(key: key, expectedETag: etag)
    }

    public func download(key: String, to destination: URL, replaceExisting: Bool, progress: @escaping TransferProgress = { _ in }) async throws {
        try await download(key: key, to: destination, replaceExisting: replaceExisting, expectedETag: nil, progress: progress)
    }

    /// Pin Finder downloads to the listed version. A changed object must not become stale local content.
    public func download(key: String, to destination: URL, replaceExisting: Bool, expectedETag: String?,
                         progress: @escaping TransferProgress = { _ in }) async throws {
        let headers = expectedETag.map { ["if-match": $0] } ?? [:]
        let (temporary, response) = try await session.download(for: request("GET", key: key, headers: headers), delegate: TransferDelegate(progress))
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            _ = try validate(response, data: (try? Data(contentsOf: temporary)) ?? Data())
        } else { _ = try validate(response) }
        try Task.checkCancellation()
        let manager = FileManager.default
        // Stage beside the destination so replacement stays on the same disk.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".r2desk-\(UUID().uuidString).download")
        try manager.copyItem(at: temporary, to: staged)
        defer { try? manager.removeItem(at: staged) }
        if manager.fileExists(atPath: destination.path) {
            guard replaceExisting else { throw StorageError.message("The download file already exists. Select another folder.") }
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else { try manager.moveItem(at: staged, to: destination) }
        progress(1)
    }

    public func createFolder(key: String) async throws {
        guard key.hasSuffix("/") else { throw StorageError.message("A folder key must end with a slash.") }
        var request = try request("PUT", key: key, headers: ["if-none-match": "*", "content-type": "application/x-directory"])
        request.httpBody = Data()
        let (data, response) = try await session.data(for: request)
        _ = try validate(response, data: data)
    }

    public func delete(key: String) async throws {
        let (data, response) = try await session.data(for: request("DELETE", key: key))
        _ = try validate(response, data: data)
    }

    public func rename(item: RemoteItem, to key: String) async throws {
        guard !item.isFolder else { throw StorageError.message("Folder rename is not available in this version.") }
        guard item.size <= 5 * 1024 * 1024 * 1024 else { throw StorageError.message("Rename supports files up to 5 GiB.") }
        guard item.key != key else { return }
        let (headData, headResponse) = try await session.data(for: request("HEAD", key: item.key))
        let head = try validate(headResponse, data: headData)
        guard let etag = head.value(forHTTPHeaderField: "ETag") else {
            throw StorageError.message("R2 returned no file checksum. The file was not renamed.")
        }
        guard let bucket else { throw StorageError.message("Open a bucket first.") }
        let source = "/" + S3Signer.encode(bucket) + "/" + S3Signer.encode(item.key, preserveSlashes: true)
        let (data, response) = try await session.data(for: request("PUT", key: key, headers: [
            "x-amz-copy-source": source, "x-amz-copy-source-if-match": etag,
            "cf-copy-destination-if-none-match": "*"
        ]))
        _ = try validate(response, data: data)
        // Keep the source if another client changed it while the copy was running.
        let (_, checkResponse) = try await session.data(for: request("HEAD", key: item.key))
        let check = try validate(checkResponse)
        guard check.value(forHTTPHeaderField: "ETag") == etag else {
            throw StorageError.message("The original file changed during rename. Both files were kept.")
        }
        try await delete(key: item.key)
    }
}

public extension S3Client {
    func metadata(key: String, expectedETag: String? = nil) async throws -> RemoteItem {
        let headers = expectedETag.map { ["if-match": $0] } ?? [:]
        let (data, response) = try await session.data(for: request("HEAD", key: key, headers: headers))
        let http = try validate(response, data: data)
        guard let etag = http.value(forHTTPHeaderField: "ETag"),
              let sizeText = http.value(forHTTPHeaderField: "Content-Length"), let size = Int64(sizeText), size >= 0 else {
            throw StorageError.message("R2 returned incomplete file details. Refresh the folder.")
        }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let modified = http.value(forHTTPHeaderField: "Last-Modified").flatMap { format.date(from: $0) }
        return RemoteItem(key: key, isFolder: key.hasSuffix("/"), size: size, modified: modified, etag: etag)
    }
    private func copyForFinder(_ item: RemoteItem, to key: String) async throws {
        guard item.size <= 5 * 1024 * 1024 * 1024, let etag = item.etag, let bucket else {
            throw StorageError.message("Finder can move files up to 5 GiB. Use a smaller file.")
        }
        let source = "/" + S3Signer.encode(bucket) + "/" + S3Signer.encode(item.key, preserveSlashes: true)
        let (data, response) = try await session.data(for: request("PUT", key: key, headers: [
            "x-amz-copy-source": source, "x-amz-copy-source-if-match": etag, "cf-copy-destination-if-none-match": "*"
        ]))
        _ = try validate(response, data: data)
    }
    /// R2 moves are copy/delete operations. Recheck source versions before deleting any source.
    func moveForFinder(item: RemoteItem, to key: String) async throws {
        try FinderIdentity.validate(key)
        guard item.key != key else { return }
        if !item.isFolder {
            guard let etag = item.etag else { throw StorageError.message("The file has no checksum. Refresh the folder.") }
            let source = try await metadata(key: item.key, expectedETag: etag)
            try await copyForFinder(source, to: key)
            _ = try await metadata(key: item.key, expectedETag: etag)
            _ = try await metadata(key: key, expectedETag: etag)
            try await delete(key: item.key)
            return
        }
        guard key.hasSuffix("/"), !key.hasPrefix(item.key) else { throw StorageError.message("A folder cannot be moved inside itself.") }
        let source = try await list(prefix: item.key, recursive: true)
        for entry in source {
            try FinderIdentity.validate(entry.key)
            guard entry.size <= 5 * 1024 * 1024 * 1024, entry.etag != nil else {
                throw StorageError.message("This folder has a file that Finder cannot move. Use R2 Desk to inspect it.")
            }
        }
        let marker: RemoteItem?
        do { marker = try await metadata(key: item.key) }
        catch StorageError.response(404, _) { marker = nil }
        guard try await list(prefix: key, recursive: true).isEmpty else { throw StorageError.response(412, "") }
        try await createFolder(key: key)
        // Finish every copy before deleting the first source. Failed copies leave source files intact.
        for entry in source {
            try Task.checkCancellation()
            try await copyForFinder(entry, to: key + entry.key.dropFirst(item.key.count))
        }
        let current = try await list(prefix: item.key, recursive: true)
        guard Set(current) == Set(source) else { throw StorageError.message("The folder changed during the move. Both folders were kept.") }
        if let marker { _ = try await metadata(key: marker.key, expectedETag: marker.etag) }
        for entry in source {
            _ = try await metadata(key: entry.key, expectedETag: entry.etag)
            _ = try await metadata(key: key + entry.key.dropFirst(item.key.count), expectedETag: entry.etag)
        }
        for entry in source { try Task.checkCancellation(); try await delete(key: entry.key) }
        if let marker { try await delete(key: marker.key) }
    }
    func deleteForFinder(item: RemoteItem, recursive: Bool) async throws {
        if !item.isFolder {
            guard let etag = item.etag else { throw StorageError.message("The file has no checksum. Refresh the folder.") }
            _ = try await metadata(key: item.key, expectedETag: etag)
            try await delete(key: item.key)
            return
        }
        let children = try await list(prefix: item.key, recursive: true)
        guard recursive || children.isEmpty else { throw StorageError.message("The folder is not empty.") }
        for entry in children {
            guard let etag = entry.etag else { throw StorageError.message("A file has no checksum. Refresh the folder.") }
            _ = try await metadata(key: entry.key, expectedETag: etag)
        }
        for entry in children { try Task.checkCancellation(); try await delete(key: entry.key) }
        // The marker can be absent for an implied R2 folder.
        do { _ = try await metadata(key: item.key); try await delete(key: item.key) }
        catch StorageError.response(404, _) {}
    }
}
