import Foundation
import Security

/// Keychain-backed `DriveCredentialStore` — the OAuth client id/secret, refresh token, and cached access
/// token live in the login Keychain (JSON-encoded `DriveCredentials`), never in a plist. Thread-safe
/// (Keychain APIs are), no mutable state → `@unchecked Sendable`.
public final class KeychainDriveCredentialStore: DriveCredentialStore, @unchecked Sendable {
    private let service: String
    private let account = "google-drive"

    public init(service: String = "com.callbrain.app.googledrive") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() -> DriveCredentials? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let creds = try? JSONDecoder().decode(DriveCredentials.self, from: data) else { return nil }
        return creds
    }

    public func save(_ c: DriveCredentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        // Update-if-present, else add — never delete the existing item before the replacement is stored, so
        // a failed write can't leave the user with no credentials (SME MED). Device-only accessibility
        // (won't sync to iCloud Keychain) for a high-value refresh token (SME LOW).
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

/// In-memory store for tests / previews.
public final class InMemoryDriveCredentialStore: DriveCredentialStore, @unchecked Sendable {
    private let lock = NSLock(); private var creds: DriveCredentials?
    public init(_ initial: DriveCredentials? = nil) { creds = initial }
    public func load() -> DriveCredentials? { lock.lock(); defer { lock.unlock() }; return creds }
    public func save(_ c: DriveCredentials) { lock.lock(); creds = c; lock.unlock() }
    public func clear() { lock.lock(); creds = nil; lock.unlock() }
}
