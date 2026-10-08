import Foundation

extension GarageEnvironment {
    public static let sandboxKeychainGroup = "SANDBOX.whisper-lift"

    /** One sandbox per process, so the doors screen, Siri's door lookup and the intents all share the same throwaway state during a UI-test run. */
    public static let sharedSandbox = sandbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("WhisperLiftSandbox-\(UUID().uuidString)", isDirectory: true))

    /** Signed out, on throwaway storage, with an in-memory Keychain and a transport that refuses every request, so it can never touch a real session or reach myQ. */
    public static func sandbox(directory: URL) -> GarageEnvironment {
        GarageEnvironment(dataDirectory: directory, keychainGroup: sandboxKeychainGroup, transport: OfflineTransport(), keychain: MemoryKeychain())
    }

    /** The one switch between the sandbox and the live environment; while sandboxed the live factory is never called, so the real App Group and Keychain are never opened. */
    public static func select(sandboxed: Bool, live: () throws -> GarageEnvironment) rethrows -> GarageEnvironment {
        sandboxed ? sharedSandbox : try live()
    }
}

/** Refuses every request before it leaves the device. */
struct OfflineTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw MyQError.transport }
}

/** An in-memory stand-in for the Keychain; each sandbox gets its own, so nothing reaches a real or shared Keychain item. */
final class MemoryKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock { stored.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil) }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            stored = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            guard stored != nil else { return errSecItemNotFound }
            stored = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            stored = nil
            return errSecSuccess
        }
    }
}
