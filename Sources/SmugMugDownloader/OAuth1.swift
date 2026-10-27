import CryptoKit
import Foundation

/// Consumer (API key) and optional token credentials for OAuth 1.0a.
struct OAuthCredentials: Codable, Sendable {
    var consumerKey: String
    var consumerSecret: String
    var token: String?
    var tokenSecret: String?
}

/// Minimal OAuth 1.0a (HMAC-SHA1) request signing, as required by the SmugMug API.
enum OAuth1 {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// Builds the `Authorization` header value for a request.
    /// `extra` holds additional oauth_* parameters such as `oauth_callback` or `oauth_verifier`.
    static func authorizationHeader(
        method: String,
        url: URL,
        credentials: OAuthCredentials,
        extra: [String: String] = [:]
    ) -> String {
        var oauth: [String: String] = [
            "oauth_consumer_key": credentials.consumerKey,
            "oauth_nonce": UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": String(Int(Date().timeIntervalSince1970)),
            "oauth_version": "1.0",
        ]
        if let token = credentials.token { oauth["oauth_token"] = token }
        oauth.merge(extra) { $1 }

        // Signature parameters: oauth params plus the URL's query parameters.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var params = oauth.map { ($0.key, $0.value) }
        for item in components?.queryItems ?? [] {
            params.append((item.name, item.value ?? ""))
        }
        let encoded: [(key: String, value: String)] = params.map { (percentEncode($0.0), percentEncode($0.1)) }
        let sorted = encoded.sorted { a, b in a.key == b.key ? a.value < b.value : a.key < b.key }
        let normalized = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        let scheme = (components?.scheme ?? "https").lowercased()
        let host = (components?.host ?? "").lowercased()
        let path = components?.percentEncodedPath ?? ""
        let baseURL = "\(scheme)://\(host)\(path)"

        let baseString = [method.uppercased(), percentEncode(baseURL), percentEncode(normalized)]
            .joined(separator: "&")
        let signingKey = percentEncode(credentials.consumerSecret) + "&"
            + percentEncode(credentials.tokenSecret ?? "")
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(baseString.utf8), using: SymmetricKey(data: Data(signingKey.utf8)))
        oauth["oauth_signature"] = Data(mac).base64EncodedString()

        let header = oauth
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\"\(percentEncode($0.value))\"" }
            .joined(separator: ", ")
        return "OAuth " + header
    }

    /// Parses an `application/x-www-form-urlencoded` response body.
    static func parseForm(_ data: Data) -> [String: String] {
        let body = String(decoding: data, as: UTF8.self)
        var result: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            result[key] = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
        }
        return result
    }
}
