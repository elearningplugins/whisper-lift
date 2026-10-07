import Foundation
import Security
import Testing
@testable import GarageDoorKit

/** Records every Keychain call and answers from memory, so no test touches the real Keychain. */
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(String, [String: Any])] = []
    var stored: Data?
    var forcedStatus: OSStatus?

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            calls.append(("copy", query))
            if let forcedStatus { return (forcedStatus, nil) }
            return stored.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            calls.append(("add", attributes))
            if let forcedStatus { return forcedStatus }
            stored = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            calls.append(("update", query.merging(attributes) { _, new in new }))
            if let forcedStatus { return forcedStatus }
            guard stored != nil else { return errSecItemNotFound }
            stored = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    var deleteStatus: OSStatus?

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            calls.append(("delete", query))
            if let deleteStatus { return deleteStatus }
            stored = nil
            return errSecSuccess
        }
    }
}

private let record = TokenRecord(accessToken: "access-SECRET", refreshToken: "refresh-SECRET", accessTokenExpiry: Date(timeIntervalSince1970: 1_790_000_000), generation: 3, lastRefresh: nil)

@Suite struct KeychainTokenStoreTests {
    private func store(_ keychain: FakeKeychain) -> KeychainTokenStore {
        KeychainTokenStore(accessGroup: "ABCDE12345.com.example.GarageTiles", backend: keychain)
    }

    @Test func everyCallTargetsTheOneSharedNonSyncingItem() throws {
        let keychain = FakeKeychain()
        let store = store(keychain)
        try store.write(record)
        _ = try store.read()
        try store.remove()
        #expect(keychain.calls.count == 4)
        for (_, query) in keychain.calls {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "GarageTiles.myQ")
            #expect(query[kSecAttrAccount as String] as? String == "token-record")
            #expect(query[kSecAttrAccessGroup as String] as? String == "ABCDE12345.com.example.GarageTiles")
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        }
    }

    @Test func writesAreAvailableAfterFirstUnlockOnThisDeviceOnly() throws {
        let keychain = FakeKeychain()
        try store(keychain).write(record)
        try store(keychain).write(record)
        let writes = keychain.calls.filter { $0.0 == "add" || $0.0 == "update" }
        #expect(writes.map(\.0) == ["update", "add", "update"])
        for (_, attributes) in writes {
            #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(attributes[kSecValueData as String] is Data)
        }
    }

    @Test func readReturnsWhatWasWritten() throws {
        let keychain = FakeKeychain()
        try store(keychain).write(record)
        #expect(try store(keychain).read() == record)
        let copy = try #require(keychain.calls.last { $0.0 == "copy" }?.1)
        #expect(copy[kSecReturnData as String] as? Bool == true)
        #expect(copy[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
    }

    @Test func missingItemReadsAsNil() throws {
        #expect(try store(FakeKeychain()).read() == nil)
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecMissingEntitlement, errSecAuthFailed])
    func lockedOrMisconfiguredKeychainIsStoreUnavailable(_ status: OSStatus) throws {
        let keychain = FakeKeychain()
        keychain.forcedStatus = status
        #expect(throws: TokenError.storeUnavailable) { try store(keychain).read() }
        #expect(throws: TokenError.storeUnavailable) { try store(keychain).write(record) }
    }

    @Test func corruptItemIsStoreUnavailable() throws {
        let keychain = FakeKeychain()
        keychain.stored = Data("not a record".utf8)
        #expect(throws: TokenError.storeUnavailable) { try store(keychain).read() }
    }

    @Test func removeDeletesTheItem() throws {
        let keychain = FakeKeychain()
        try store(keychain).write(record)
        try store(keychain).remove()
        #expect(try store(keychain).read() == nil)
    }
}
