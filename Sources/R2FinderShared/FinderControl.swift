import Foundation
import R2Core

public struct FinderConfiguration: Codable, Sendable, Equatable {
    public let connection: Connection
    public let bucket: String
    public init(connection: Connection, bucket: String) { self.connection = connection; self.bucket = bucket }
    public var identifier: String { FinderIdentity.domain(connection: connection, bucket: bucket) }
    public func validate() throws { try connection.validate(); try RemoteBucket.validateName(bucket) }
    /// Domain IDs bind an extension to one endpoint. This also works on macOS 14, without domain.userInfo.
    public static func parse(identifier: String) throws -> FinderConfiguration {
        let parts = identifier.split(separator: ".", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "r2desk", let id = UUID(uuidString: parts[1]) else {
            throw StorageError.message("The Finder drive ID is invalid.")
        }
        let config = FinderConfiguration(connection: Connection(id: id, name: "R2 connection", accountID: parts[2],
                                                                jurisdiction: parts[3] == "default" ? "" : parts[3]), bucket: parts[4])
        try config.validate()
        guard config.identifier == identifier else { throw StorageError.message("The Finder drive ID is invalid.") }
        return config
    }
}

public struct FinderAccess: Codable, Sendable {
    public let configuration: FinderConfiguration
    public let credentials: Credentials
    public init(configuration: FinderConfiguration, credentials: Credentials) {
        self.configuration = configuration; self.credentials = credentials
    }
}

public enum FinderControl {
    public static let serviceName = "com.busha.r2desk.finder.control"
}

@objc public protocol FinderControlProtocol {
    func configure(_ payload: Data, reply: @escaping (NSError?) -> Void)
    func refresh(reply: @escaping (NSError?) -> Void)
    func revoke(reply: @escaping (NSError?) -> Void)
}
