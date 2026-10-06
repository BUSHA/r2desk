import Foundation

public enum BrowserLocation: Equatable, Sendable {
    case buckets
    case folder(bucket: String, prefix: String)

    public var bucket: String? {
        if case .folder(let bucket, _) = self { return bucket }
        return nil
    }
    public var prefix: String {
        if case .folder(_, let prefix) = self { return prefix }
        return ""
    }
    public var title: String {
        guard let bucket else { return "Buckets" }
        return prefix.isEmpty ? bucket : String(prefix.dropLast()).components(separatedBy: "/").last ?? "Folder"
    }
    public var parent: BrowserLocation? {
        guard let bucket else { return nil }
        guard !prefix.isEmpty else { return .buckets }
        let parts = prefix.split(separator: "/").dropLast()
        return .folder(bucket: bucket, prefix: parts.isEmpty ? "" : parts.joined(separator: "/") + "/")
    }
}

public struct BrowserHistory {
    private var locations: [BrowserLocation]
    private var index = 0
    public var location: BrowserLocation { locations[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < locations.count }
    public init(location: BrowserLocation = .buckets) { locations = [location] }
    @discardableResult public mutating func navigate(_ location: BrowserLocation) -> Bool {
        guard location != self.location else { return false }
        locations = Array(locations.prefix(index + 1)); locations.append(location); index += 1
        return true
    }
    @discardableResult public mutating func back() -> Bool {
        guard canGoBack else { return false }
        index -= 1; return true
    }
    @discardableResult public mutating func forward() -> Bool {
        guard canGoForward else { return false }
        index += 1; return true
    }
}
