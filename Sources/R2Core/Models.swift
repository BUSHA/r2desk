import Foundation

public struct Connection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var accountID: String
    public var jurisdiction: String

    public init(id: UUID = UUID(), name: String, accountID: String, jurisdiction: String = "") {
        self.id = id; self.name = name; self.accountID = accountID
        self.jurisdiction = jurisdiction
    }

    public var endpoint: URL {
        let region = jurisdiction.isEmpty ? "" : ".\(jurisdiction)"
        return URL(string: "https://\(accountID)\(region).r2.cloudflarestorage.com")!
    }

    public func validate() throws {
        guard accountID.count == 32, accountID.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw StorageError.message("Enter the 32-character Cloudflare account ID.")
        }
        guard ["", "eu", "us", "fedramp"].contains(jurisdiction) else {
            throw StorageError.message("Select a supported storage location.")
        }
    }
}

public struct RemoteBucket: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let created: Date?
    public init(name: String, created: Date? = nil) {
        self.name = name; self.created = created
    }
    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard (3...63).contains(name.count), name.unicodeScalars.allSatisfy(allowed.contains),
              name.first?.isLetter == true || name.first?.isNumber == true,
              name.last?.isLetter == true || name.last?.isNumber == true,
              !name.contains(".."), !name.contains(".-"), !name.contains("-.") else {
            throw StorageError.message("R2 returned an invalid bucket name.")
        }
    }
}

public struct Credentials: Codable, Sendable {
    public let accessKey: String
    public let secretKey: String
    public init(accessKey: String, secretKey: String) {
        self.accessKey = accessKey; self.secretKey = secretKey
    }
}

public struct RemoteItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let isFolder: Bool
    public let size: Int64
    public let modified: Date?
    public let etag: String?
    public var name: String {
        let trimmed = isFolder && key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.components(separatedBy: "/").last ?? trimmed
    }
    public init(key: String, isFolder: Bool = false, size: Int64 = 0, modified: Date? = nil, etag: String? = nil) {
        self.key = key; self.isFolder = isFolder; self.size = size
        self.modified = modified; self.etag = etag
    }
}

public enum StorageError: LocalizedError {
    case message(String)
    case response(Int, String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .response(let status, let detail):
            if status == 401 || status == 403 { return "R2 refused access. Check the keys, bucket name, and token permissions. \(detail)" }
            if status == 412 { return "The file already exists or has changed. Refresh the folder and try again." }
            return "R2 returned HTTP \(status). \(detail)"
        }
    }
}

public enum FilePaths {
    public static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0"), !name.contains("\n"), !name.contains("\r") else {
            throw StorageError.message("Enter a name without a slash or a line break.")
        }
    }

    /// Reject unsafe keys instead of silently changing a remote file name.
    public static func localURL(root: URL, relativeKey: String) throws -> URL {
        let parts = relativeKey.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativeKey.hasPrefix("/"), !parts.isEmpty else {
            throw StorageError.message("This file path cannot be saved on your Mac.")
        }
        var result = root.standardizedFileURL
        for part in parts {
            try validateName(String(part))
            result.appendPathComponent(String(part))
            // Do not follow a local link outside the selected folder.
            let values = try? result.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw StorageError.message("The download path contains a symbolic link. Select another folder.")
            }
        }
        let base = root.standardizedFileURL.path + "/"
        guard result.standardizedFileURL.path.hasPrefix(base) else {
            throw StorageError.message("The download path is outside the selected folder.")
        }
        return result
    }
}

public typealias TransferProgress = @Sendable (Double) -> Void

public protocol StorageService: Sendable {
    func list(prefix: String, recursive: Bool) async throws -> [RemoteItem]
    func upload(file: URL, key: String, replacingETag: String?, progress: @escaping TransferProgress) async throws
    func download(key: String, to: URL, replaceExisting: Bool, progress: @escaping TransferProgress) async throws
    func createFolder(key: String) async throws
    func delete(key: String) async throws
    func rename(item: RemoteItem, to: String) async throws
}

public extension StorageService {
    func download(key: String, to: URL, progress: @escaping TransferProgress) async throws {
        try await download(key: key, to: to, replaceExisting: false, progress: progress)
    }
}
