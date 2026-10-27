import Foundation

struct SmugMugError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - API models (only the fields we use)

struct APIEnvelope<T: Decodable>: Decodable {
    let response: T
    enum CodingKeys: String, CodingKey { case response = "Response" }
}

struct UriRef: Decodable {
    let uri: String
    enum CodingKeys: String, CodingKey { case uri = "Uri" }
}

struct Pages: Decodable {
    let nextPage: String?
    enum CodingKeys: String, CodingKey { case nextPage = "NextPage" }
}

struct UserResponse: Decodable {
    let user: User
    enum CodingKeys: String, CodingKey { case user = "User" }
}

struct User: Decodable {
    let name: String?
    let nickName: String
    let uris: Uris
    struct Uris: Decodable {
        let node: UriRef
        enum CodingKeys: String, CodingKey { case node = "Node" }
    }
    enum CodingKeys: String, CodingKey { case name = "Name", nickName = "NickName", uris = "Uris" }
}

struct NodeResponse: Decodable {
    let node: Node
    enum CodingKeys: String, CodingKey { case node = "Node" }
}

struct NodeListResponse: Decodable {
    let nodes: [Node]?
    let pages: Pages?
    enum CodingKeys: String, CodingKey { case nodes = "Node", pages = "Pages" }
}

struct Node: Decodable {
    let name: String
    let type: String
    let uris: Uris
    struct Uris: Decodable {
        let childNodes: UriRef?
        let album: UriRef?
        enum CodingKeys: String, CodingKey { case childNodes = "ChildNodes", album = "Album" }
    }
    enum CodingKeys: String, CodingKey { case name = "Name", type = "Type", uris = "Uris" }
}

struct AlbumImagesResponse: Decodable {
    let images: [AlbumImage]?
    let pages: Pages?
    enum CodingKeys: String, CodingKey { case images = "AlbumImage", pages = "Pages" }
}

struct AlbumImage: Decodable {
    let fileName: String?
    let imageKey: String
    let archivedUri: String?
    let archivedSize: Int64?
    let isVideo: Bool?
    enum CodingKeys: String, CodingKey {
        case fileName = "FileName", imageKey = "ImageKey", archivedUri = "ArchivedUri"
        case archivedSize = "ArchivedSize", isVideo = "IsVideo"
    }
}

// MARK: - Client

final class SmugMugClient: Sendable {
    static let apiBase = "https://api.smugmug.com"
    private static let oauthBase = "https://api.smugmug.com/services/oauth/1.0a"

    let credentials: OAuthCredentials
    private let session: URLSession

    init(credentials: OAuthCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: config)
    }

    // MARK: Sign-in (PIN / out-of-band flow)

    static func requestToken(consumerKey: String, consumerSecret: String) async throws -> (token: String, secret: String) {
        let url = URL(string: "\(oauthBase)/getRequestToken")!
        let creds = OAuthCredentials(consumerKey: consumerKey, consumerSecret: consumerSecret)
        var request = URLRequest(url: url)
        request.setValue(
            OAuth1.authorizationHeader(method: "GET", url: url, credentials: creds, extra: ["oauth_callback": "oob"]),
            forHTTPHeaderField: "Authorization")
        let form = try await formRequest(request)
        guard let token = form["oauth_token"], let secret = form["oauth_token_secret"] else {
            throw SmugMugError("SmugMug did not return a request token. Check your API key and secret.")
        }
        return (token, secret)
    }

    static func authorizeURL(requestToken: String) -> URL {
        var components = URLComponents(string: "\(oauthBase)/authorize")!
        components.queryItems = [
            URLQueryItem(name: "oauth_token", value: requestToken),
            URLQueryItem(name: "Access", value: "Full"),  // needed to see private galleries
            URLQueryItem(name: "Permissions", value: "Read"),
        ]
        return components.url!
    }

    static func accessToken(
        consumerKey: String, consumerSecret: String,
        requestToken: String, requestSecret: String, verifier: String
    ) async throws -> (token: String, secret: String) {
        let url = URL(string: "\(oauthBase)/getAccessToken")!
        let creds = OAuthCredentials(
            consumerKey: consumerKey, consumerSecret: consumerSecret,
            token: requestToken, tokenSecret: requestSecret)
        var request = URLRequest(url: url)
        request.setValue(
            OAuth1.authorizationHeader(method: "GET", url: url, credentials: creds, extra: ["oauth_verifier": verifier]),
            forHTTPHeaderField: "Authorization")
        let form = try await formRequest(request)
        guard let token = form["oauth_token"], let secret = form["oauth_token_secret"] else {
            throw SmugMugError("SmugMug did not accept that code. Start sign-in again and enter the new code.")
        }
        return (token, secret)
    }

    private static func formRequest(_ request: URLRequest) async throws -> [String: String] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw SmugMugError("SmugMug sign-in failed (HTTP \(status)): \(body)")
        }
        return OAuth1.parseForm(data)
    }

    // MARK: API calls

    func url(for uri: String) throws -> URL {
        let string = uri.hasPrefix("http") ? uri : Self.apiBase + uri
        guard let url = URL(string: string) else { throw SmugMugError("Bad URL: \(string)") }
        return url
    }

    private func signedRequest(_ url: URL, accept: String? = "application/json") -> URLRequest {
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        request.setValue(
            OAuth1.authorizationHeader(method: "GET", url: url, credentials: credentials),
            forHTTPHeaderField: "Authorization")
        return request
    }

    func get<T: Decodable>(_ uri: String, as type: T.Type) async throws -> T {
        let url = try url(for: uri)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: signedRequest(url))
            } catch let error as URLError where error.code != .cancelled && attempt < 6 {
                try await backoff(attempt)
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if Self.isRetryable(status) && attempt < 6 {
                try await backoff(attempt)
                continue
            }
            guard (200..<300).contains(status) else {
                if status == 401 { throw SmugMugError("SmugMug rejected the saved sign-in (HTTP 401). Sign out and sign in again.") }
                throw SmugMugError("HTTP \(status) for \(url.absoluteString)")
            }
            return try JSONDecoder().decode(APIEnvelope<T>.self, from: data).response
        }
    }

    /// Downloads a file to a temporary location and returns its URL. The caller must move or delete it.
    func download(_ uri: String) async throws -> URL {
        let url = try url(for: uri)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let tempURL: URL
            let response: URLResponse
            do {
                (tempURL, response) = try await session.download(for: signedRequest(url, accept: nil))
            } catch let error as URLError where error.code != .cancelled && attempt < 6 {
                try await backoff(attempt)
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return tempURL }
            try? FileManager.default.removeItem(at: tempURL)
            if Self.isRetryable(status) && attempt < 6 {
                try await backoff(attempt)
                continue
            }
            throw SmugMugError("HTTP \(status) downloading \(url.lastPathComponent)")
        }
    }

    private static func isRetryable(_ status: Int) -> Bool { status == 429 || status >= 500 }

    private func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
    }
}

extension String {
    /// Appends query parameters to a SmugMug URI that may already contain a query string.
    func appendingQuery(_ query: String) -> String {
        contains("?") ? "\(self)&\(query)" : "\(self)?\(query)"
    }
}
