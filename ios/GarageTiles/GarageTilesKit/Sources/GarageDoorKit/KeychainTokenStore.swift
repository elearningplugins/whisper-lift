import Foundation
import Security

/** The four Keychain calls the token store makes, so tests can check every query without touching the real Keychain. */
public protocol KeychainBackend: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

/** Passes straight through to SecItem; it holds no logic of its own. */
public struct SecItemBackend: KeychainBackend {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/** The single shared token record: data-protection Keychain, shared access group, never synced, readable after first unlock on this device only. */
public struct KeychainTokenStore: TokenStore {
    public let accessGroup: String
    let backend: any KeychainBackend

    public init(accessGroup: String, backend: any KeychainBackend = SecItemBackend()) {
        self.accessGroup = accessGroup
        self.backend = backend
    }

    public func read() throws -> TokenRecord? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data, let record = try? JSONDecoder().decode(TokenRecord.self, from: data) else { throw TokenError.storeUnavailable }
            return record
        case errSecItemNotFound:
            return nil
        default:
            throw TokenError.storeUnavailable
        }
    }

    public func write(_ record: TokenRecord) throws {
        guard let data = try? JSONEncoder().encode(record) else { throw TokenError.storeUnavailable }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = backend.update(baseQuery(), attributes)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw TokenError.storeUnavailable }
        guard backend.add(baseQuery().merging(attributes) { _, new in new }) == errSecSuccess else { throw TokenError.storeUnavailable }
    }

    /** Removes the token, for the app's "Remove token" action. */
    public func remove() throws {
        let status = backend.delete(baseQuery())
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TokenError.storeUnavailable }
    }

    func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "GarageTiles.myQ",
            kSecAttrAccount as String: "token-record",
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
