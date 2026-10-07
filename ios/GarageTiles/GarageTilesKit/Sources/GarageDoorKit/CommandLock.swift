import CryptoKit
import Foundation

public enum CommandLockError: Error, Equatable, Sendable {
    case busy
    case unavailable
}

/** Serializes the final live read, decision and send for one door across every process that can command it. */
public protocol CommandLocking: Sendable {
    func withDoorLock<T: Sendable>(_ door: DoorIdentity, _ body: @Sendable () async throws -> T) async throws -> T
}

/** A per-door flock in the App Group; a holder in another process makes a new request wait briefly, then refuse as in flight. */
public struct FileCommandLock: CommandLocking {
    public let directory: URL
    public let timeout: Duration

    public init(directory: URL, timeout: Duration = .milliseconds(500)) {
        self.directory = directory
        self.timeout = timeout
    }

    /** The lock file is named by a hash of the door identity, so no serial or account ID appears in a file name. */
    public func url(for door: DoorIdentity) -> URL {
        let digest = SHA256.hash(data: Data(door.entityIdentifier.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("command-\(digest).lock", isDirectory: false)
    }

    public func withDoorLock<T: Sendable>(_ door: DoorIdentity, _ body: @Sendable () async throws -> T) async throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CommandLockError.unavailable
        }
        do {
            return try await FileLock(url: url(for: door)).withLock(timeout: timeout, body)
        } catch TokenError.lockTimedOut {
            throw CommandLockError.busy
        } catch TokenError.storeUnavailable {
            throw CommandLockError.unavailable
        }
    }
}
