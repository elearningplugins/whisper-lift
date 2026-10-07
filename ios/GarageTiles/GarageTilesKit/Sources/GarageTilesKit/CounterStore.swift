import Foundation

/** A file-backed counter that serializes increments across processes with an advisory lock and replaces its data file atomically. */
public struct CounterStore: Sendable {
    public enum StoreError: Error, Equatable {
        case directoryUnavailable
        case lockUnavailable(errno: Int32)
        case lockTimedOut
        case unreadable
        case malformedData
        case writeFailed
    }

    public static let dataFileName = "spike-counter.json"
    public static let lockFileName = "spike-counter.lock"

    public let directory: URL
    public let lockTimeout: Duration
    // Attempts a non-blocking exclusive lock and returns 0 or the errno; replaceable so tests can inject lock failures.
    let tryLock: @Sendable (Int32) -> Int32

    public init(directory: URL, lockTimeout: Duration = .seconds(2)) {
        self.init(directory: directory, lockTimeout: lockTimeout) { descriptor in
            flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? 0 : errno
        }
    }

    init(directory: URL, lockTimeout: Duration, tryLock: @escaping @Sendable (Int32) -> Int32) {
        self.directory = directory
        self.lockTimeout = lockTimeout
        self.tryLock = tryLock
    }

    var dataURL: URL { directory.appendingPathComponent(Self.dataFileName, isDirectory: false) }
    var lockURL: URL { directory.appendingPathComponent(Self.lockFileName, isDirectory: false) }

    /** Returns the current snapshot, or an empty snapshot when nothing has been written yet. */
    public func read() throws -> CounterSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: dataURL)
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            throw StoreError.unreadable
        }
        do {
            return try Self.decoder.decode(CounterSnapshot.self, from: data)
        } catch {
            throw StoreError.malformedData
        }
    }

    /** Adds one tap for the tile while holding the interprocess lock and returns the stored result. */
    @discardableResult
    public func increment(tile: SpikeTile, writer: String?, now: Date = Date()) throws -> CounterSnapshot {
        try withExclusiveLock {
            try write(read().incremented(tile: tile, writer: writer, at: now))
        }
    }

    /** Writes the snapshot and returns it as a later read will decode it, since ISO 8601 storage drops sub-second precision. */
    private func write(_ snapshot: CounterSnapshot) throws -> CounterSnapshot {
        let data: Data
        let stored: CounterSnapshot
        do {
            data = try Self.encoder.encode(snapshot)
            stored = try Self.decoder.decode(CounterSnapshot.self, from: data)
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
        return stored
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.directoryUnavailable
        }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw StoreError.lockUnavailable(errno: errno) }
        defer { close(descriptor) }
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: lockURL.path)
        #endif

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: lockTimeout)
        while case let code = tryLock(descriptor), code != 0 {
            guard code == EWOULDBLOCK || code == EINTR else { throw StoreError.lockUnavailable(errno: code) }
            guard clock.now < deadline else { throw StoreError.lockTimedOut }
            usleep(5_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
