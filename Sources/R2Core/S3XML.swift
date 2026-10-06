import Foundation

public final class S3XML: NSObject, XMLParserDelegate {
    public private(set) var items: [RemoteItem] = []
    public private(set) var buckets: [RemoteBucket] = []
    public private(set) var rootElement: String?
    public private(set) var nextToken: String?
    public private(set) var truncated = false
    public private(set) var errorCode: String?
    public private(set) var message: String?
    private var stack: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var prefixes: [String] = []
    private var urlEncoded = false

    public static func parse(_ data: Data) throws -> S3XML {
        let result = S3XML()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = result
        guard parser.parse() else { throw StorageError.message("R2 returned an invalid XML response.") }
        if result.urlEncoded {
            result.items = result.items.map {
                RemoteItem(key: $0.key.removingPercentEncoding ?? $0.key, isFolder: $0.isFolder,
                           size: $0.size, modified: $0.modified, etag: $0.etag)
            }
            result.prefixes = result.prefixes.map { $0.removingPercentEncoding ?? $0 }
        }
        result.items += result.prefixes.map { RemoteItem(key: $0, isFolder: true) }
        return result
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if stack.isEmpty { rootElement = name }
        stack.append(name); text = ""
        if name == "Contents" || name == "Bucket" { fields = [:] }
    }
    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = stack.dropLast().last
        if parent == "Contents" { fields[name] = text }
        if parent == "Bucket" { fields[name] = text }
        if name == "Bucket", parent == "Buckets", let bucket = fields["Name"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let created = fields["CreationDate"].flatMap { value -> Date? in
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }
            buckets.append(RemoteBucket(name: bucket, created: created))
        }
        if name == "Contents", let key = fields["Key"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = fields["LastModified"].flatMap { value -> Date? in
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: value)
            }
            items.append(RemoteItem(key: key, isFolder: key.hasSuffix("/"), size: Int64(fields["Size"] ?? "") ?? 0,
                                    modified: date, etag: fields["ETag"]))
        }
        if name == "Prefix" && parent == "CommonPrefixes" { prefixes.append(text) }
        if name == "EncodingType" { urlEncoded = text == "url" }
        if name == "NextContinuationToken" { nextToken = text.isEmpty ? nil : text }
        if name == "IsTruncated" { truncated = text == "true" }
        if name == "Code" && parent == "Error" { errorCode = text }
        if name == "Message" && parent == "Error" { message = text }
        stack.removeLast(); text = ""
    }
}
