import Foundation
import Security

/// Keychain-backed `FathomCredentialStore` — the Fathom API key (+ last-sync watermark) live in the login
/// Keychain as JSON, device-only, never in a plist. Thread-safe (Keychain APIs are) → `@unchecked Sendable`.
public final class KeychainFathomStore: FathomCredentialStore, @unchecked Sendable {
    private let service: String
    private let account = "fathom"

    public init(service: String = "com.callbrain.app.fathom") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> FathomCredentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let creds = try? JSONDecoder().decode(FathomCredentials.self, from: data) else { return nil }
        return creds
    }

    @discardableResult
    public func save(_ c: FathomCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(c) else { return false }
        // Update-if-present, else add — never delete before the replacement is stored (no creds gap).
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            if addStatus == errSecDuplicateItem {
                return SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary) == errSecSuccess
            }
        }
        return false
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

/// In-memory store for tests.
public final class InMemoryFathomStore: FathomCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var creds: FathomCredentials?
    public init(_ creds: FathomCredentials? = nil) { self.creds = creds }
    public func load() -> FathomCredentials? { lock.lock(); defer { lock.unlock() }; return creds }
    @discardableResult public func save(_ c: FathomCredentials) -> Bool { lock.lock(); creds = c; lock.unlock(); return true }
    public func clear() { lock.lock(); creds = nil; lock.unlock() }
}
