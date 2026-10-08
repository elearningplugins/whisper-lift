#if DEBUG
import Foundation
import GarageDoorKit

/** UI tests launch the app with this flag so it starts signed out on throwaway storage and can never reach myQ; Debug builds only, so a release ignores it. */
enum UITestSandbox {
    static let argument = "-WhisperLiftUITestSandbox"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static func environment() -> GarageEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UITestSandbox-\(UUID().uuidString)", isDirectory: true)
        return GarageEnvironment(dataDirectory: directory, keychainGroup: "SANDBOX.whisper-lift", transport: OfflineTransport(), keychain: MemoryKeychain())
    }
}

/** Refuses every request, so a sandboxed run can never send anything to myQ. */
struct OfflineTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw MyQError.transport }
}

/** An in-memory stand-in for the Keychain, so a sandboxed run never reads or changes the real session. */
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
#endif
