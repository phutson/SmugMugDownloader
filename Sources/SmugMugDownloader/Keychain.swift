import Foundation
import Security

/// Stores the API key/secret and OAuth access token in the login Keychain.
enum Keychain {
    private static let service = "SmugMugDownloader"
    private static let account = "credentials"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ credentials: OAuthCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> OAuthCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }
}
