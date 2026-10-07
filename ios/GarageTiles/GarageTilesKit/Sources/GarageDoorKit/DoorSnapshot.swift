import Foundation

/** A sanitized failure category shown with a cached door; never a response body or credential. */
public enum DoorProblem: String, Codable, Sendable {
    case signInRequired
    case uncertainCommand
    case unreachable
    case rateLimited
}

/** The non-secret cached view of one door shared by the app and widget through the App Group. */
public struct DoorSnapshot: Codable, Equatable, Sendable {
    public let device: DoorDevice
    public let fetchedAt: Date
    public let lastCommand: DoorAction?
    public let lastCommandAt: Date?
    public let problem: DoorProblem?

    public init(device: DoorDevice, fetchedAt: Date, lastCommand: DoorAction?, lastCommandAt: Date?, problem: DoorProblem?) {
        self.device = device
        self.fetchedAt = fetchedAt
        self.lastCommand = lastCommand
        self.lastCommandAt = lastCommandAt
        self.problem = problem
    }

    func marking(_ problem: DoorProblem?) -> DoorSnapshot {
        DoorSnapshot(device: device, fetchedAt: fetchedAt, lastCommand: lastCommand, lastCommandAt: lastCommandAt, problem: problem)
    }
}

public protocol SnapshotStoring: Sendable {
    func snapshot(for identity: DoorIdentity) throws -> DoorSnapshot?
    func upsert(_ snapshot: DoorSnapshot) throws
}

/** A JSON file of door snapshots in the App Group, replaced atomically under a cross-process flock. */
public struct DoorSnapshotStore: SnapshotStoring {
    public enum StoreError: Error, Equatable, Sendable {
        case directoryUnavailable
        case lockUnavailable
        case lockTimedOut
        case unreadable
        case malformedData
        case writeFailed
    }

    public let directory: URL
    public let lockTimeout: Duration
    // Attempts a non-blocking exclusive lock and returns 0 or the errno; replaceable so tests can inject lock failures.
    let tryLock: @Sendable (Int32) -> Int32

    public init(directory: URL, lockTimeout: Duration = .seconds(2)) {
        self.init(directory: directory, lockTimeout: lockTimeout) { flock($0, LOCK_EX | LOCK_NB) == 0 ? 0 : errno }
    }

    init(directory: URL, lockTimeout: Duration, tryLock: @escaping @Sendable (Int32) -> Int32) {
        self.directory = directory
        self.lockTimeout = lockTimeout
        self.tryLock = tryLock
    }

    var dataURL: URL { directory.appendingPathComponent("doors.json", isDirectory: false) }
    var lockURL: URL { directory.appendingPathComponent("doors.lock", isDirectory: false) }

    public func read() throws -> [DoorSnapshot] {
        let data: Data
        do {
            data = try Data(contentsOf: dataURL)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw StoreError.unreadable
        }
        do {
            return try Self.decoder.decode([DoorSnapshot].self, from: data)
        } catch {
            throw StoreError.malformedData
        }
    }

    public func snapshot(for identity: DoorIdentity) throws -> DoorSnapshot? {
        try read().first { $0.device.identity == identity }
    }

    public func upsert(_ snapshot: DoorSnapshot) throws {
        try withExclusiveLock {
            var all = try read()
            if let index = all.firstIndex(where: { $0.device.identity == snapshot.device.identity }) {
                all[index] = snapshot
            } else {
                all.append(snapshot)
            }
            let data: Data
            do {
                data = try Self.encoder.encode(all)
            } catch {
                throw StoreError.writeFailed
            }
            #if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #else
            let options: Data.WritingOptions = [.atomic]
            #endif
            do {
                try data.write(to: dataURL, options: options)
            } catch {
                throw StoreError.writeFailed
            }
        }
    }

    /** Deletes every cached door state under the store's lock; a file that was never written counts as deleted. */
    public func removeAll() throws {
        try withExclusiveLock {
            do {
                try FileManager.default.removeItem(at: dataURL)
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                throw StoreError.writeFailed
            }
        }
    }

    private func withExclusiveLock(_ body: () throws -> Void) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.directoryUnavailable
        }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StoreError.lockUnavailable }
        defer { close(descriptor) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: lockTimeout)
        while case let code = tryLock(descriptor), code != 0 {
            guard code == EWOULDBLOCK || code == EINTR else { throw StoreError.lockUnavailable }
            guard clock.now < deadline else { throw StoreError.lockTimedOut }
            usleep(5_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

/** What a widget tile shows for a cached snapshot; a stale state is always marked, and only a confirmed online terminal state offers an action. */
public struct TilePresentation: Equatable, Sendable {
    public let title: String
    public let status: String
    public let symbol: String
    public let isStale: Bool
    public let age: String?
    public let action: DoorAction?

    public init(title: String, status: String, symbol: String, isStale: Bool, age: String?, action: DoorAction?) {
        self.title = title
        self.status = status
        self.symbol = symbol
        self.isStale = isStale
        self.age = age
        self.action = action
    }

    public init(snapshot: DoorSnapshot?, now: Date, staleAfter: TimeInterval = 300) {
        guard let snapshot else {
            self.init(title: "Garage", status: "Set Up", symbol: "questionmark.square.dashed", isStale: true, age: nil, action: nil)
            return
        }
        let device = snapshot.device
        let ageSeconds = max(0, now.timeIntervalSince(snapshot.fetchedAt))
        let status: String
        switch (snapshot.problem, device.online) {
        case (.signInRequired?, _): status = "Sign In Again"
        case (.uncertainCommand?, _): status = "Check Door"
        case (_, let online) where online != true: status = "Offline"
        default: status = device.state.label
        }
        let action: DoorAction? = switch (snapshot.problem, device.online, device.state) {
        case (nil, true?, .closed): .open
        case (nil, true?, .open): .close
        default: nil
        }
        self.init(title: device.name, status: status, symbol: Self.symbol(for: device.state), isStale: ageSeconds >= staleAfter, age: Self.ageText(ageSeconds), action: action)
    }

    static func symbol(for state: DoorState) -> String {
        switch state {
        case .open: "door.garage.open"
        case .closed: "door.garage.closed"
        case .opening, .closing: "door.garage.double.bay.open"
        case .stopped, .unknown: "exclamationmark.triangle"
        }
    }

    static func ageText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(Int(seconds / 60))m ago"
        case ..<86_400: "\(Int(seconds / 3600))h ago"
        default: "\(Int(seconds / 86_400))d ago"
        }
    }
}
