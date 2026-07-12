import Foundation
import Security

/// Small generic keychain secret (calendar gate HIGH: the Google Calendar refresh token was in
/// UserDefaults — plaintext on disk). Same generic-password shape as the Drive credential store.
public struct KeychainSecret: Sendable {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service; self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(baseQuery as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    public func delete() -> Bool {
        SecItemDelete(baseQuery as CFDictionary) == errSecSuccess
    }

    /// All account names stored under a service (calendar v3: one Google Calendar refresh
    /// token per connected account — Settings lists them).
    public static func accounts(service: String) -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
