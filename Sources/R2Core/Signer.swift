import Foundation
import CryptoKit

public enum S3Signer {
    public static func encode(_ value: String, preserveSlashes: Bool = false) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            case 47 where preserveSlashes: return "/"
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func fileHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func request(endpoint: URL, bucket: String, key: String = "", method: String,
                               query: [String: String] = [:], headers: [String: String] = [:],
                               payloadHash: String = hash(Data()), credentials: Credentials,
                               date: Date = Date(), region: String = "auto") throws -> URLRequest {
        let path = "/" + encode(bucket) + (key.isEmpty ? "" : "/" + encode(key, preserveSlashes: true))
        let encodedPairs: [(String, String)] = query.map { (encode($0.key), encode($0.value)) }
        let sortedPairs = encodedPairs.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        let queryParts: [String] = sortedPairs.map { $0.0 + "=" + $0.1 }
        let canonicalQuery = queryParts.joined(separator: "&")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host else { throw StorageError.message("The R2 endpoint is invalid.") }
        components.percentEncodedPath = path
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        guard let url = components.url else { throw StorageError.message("The file URL is invalid.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        var allHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        allHeaders["host"] = host + (components.port.map { ":\($0)" } ?? "")
        allHeaders["x-amz-date"] = timestamp
        allHeaders["x-amz-content-sha256"] = payloadHash
        let names = allHeaders.keys.sorted()
        let canonicalHeaders = names.map {
            let value = allHeaders[$0]!.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return "\($0):\(value)\n"
        }.joined()
        let signedHeaders = names.joined(separator: ";")
        let canonical = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope, hash(Data(canonical.utf8))].joined(separator: "\n")
        func hmac(_ key: Data, _ text: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
        }
        let dayKey = hmac(Data(("AWS4" + credentials.secretKey).utf8), day)
        let signingKey = hmac(hmac(hmac(dayKey, region), "s3"), "aws4_request")
        let signature = hmac(signingKey, stringToSign).map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        for (name, value) in allHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
}
