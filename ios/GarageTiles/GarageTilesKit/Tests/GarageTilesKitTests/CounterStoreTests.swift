import Foundation
import Testing
@testable import GarageTilesKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GarageTilesKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct CounterStoreTests {
    @Test func readReturnsEmptySnapshotBeforeFirstWrite() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        #expect(try store.read() == .empty)
    }

    @Test func readReturnsEmptySnapshotWhenDirectoryDoesNotExistYet() throws {
        let directory = try temporaryDirectory().appendingPathComponent("NotCreated", isDirectory: true)
        #expect(try CounterStore(directory: directory).read() == .empty)
    }

    @Test func incrementRecordsTileWriterAndTime() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        let result = try store.increment(tile: .bravo, writer: "com.example.widget", now: now)

        #expect(result.total == 1)
        #expect(result.taps(for: .bravo) == 1)
        #expect(result.taps(for: .alpha) == 0)
        #expect(result.lastTile == .bravo)
        #expect(result.lastWriter == "com.example.widget")
        #expect(result.lastTapAt == now)
        #expect(try store.read() == result)
    }

    @Test func tilesAreCountedSeparatelyAndTotalAcrossBoth() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        try store.increment(tile: .alpha, writer: nil)
        try store.increment(tile: .alpha, writer: nil)
        try store.increment(tile: .bravo, writer: nil)

        let snapshot = try store.read()
        #expect(snapshot.total == 3)
        #expect(snapshot.taps(for: .alpha) == 2)
        #expect(snapshot.taps(for: .bravo) == 1)
        #expect(snapshot.lastTile == .bravo)
    }

    @Test func separateStoreInstancesShareTheSameFile() throws {
        let directory = try temporaryDirectory()
        try CounterStore(directory: directory).increment(tile: .alpha, writer: "app")
        try CounterStore(directory: directory).increment(tile: .alpha, writer: "widget")

        let snapshot = try CounterStore(directory: directory).read()
        #expect(snapshot.total == 2)
        #expect(snapshot.lastWriter == "widget")
    }

    @Test func concurrentIncrementsFromIndependentInstancesAreNotLost() throws {
        let directory = try temporaryDirectory()
        let workers = 8
        let incrementsPerWorker = 25
        let failures = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: workers) { index in
            let store = CounterStore(directory: directory, lockTimeout: .seconds(30))
            let tile: SpikeTile = index.isMultiple(of: 2) ? .alpha : .bravo
            for _ in 0..<incrementsPerWorker {
                do { try store.increment(tile: tile, writer: "worker-\(index)") } catch { failures.add() }
            }
        }

        let snapshot = try CounterStore(directory: directory).read()
        #expect(failures.value == 0)
        #expect(snapshot.total == workers * incrementsPerWorker)
        #expect(snapshot.taps(for: .alpha) + snapshot.taps(for: .bravo) == snapshot.total)
        #expect(snapshot.taps(for: .alpha) == workers / 2 * incrementsPerWorker)
    }

    @Test func incrementTimesOutWhileAnotherHolderHasTheLock() throws {
        let directory = try temporaryDirectory()
        let store = CounterStore(directory: directory, lockTimeout: .milliseconds(50))
        let holder = open(store.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)

        #expect(throws: CounterStore.StoreError.lockTimedOut) {
            try store.increment(tile: .alpha, writer: nil)
        }
        #expect(try store.read() == .empty)

        flock(holder, LOCK_UN)
        #expect(try store.increment(tile: .alpha, writer: nil).total == 1)
    }

    @Test func malformedDataIsReportedAndNotOverwritten() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        let garbage = Data("not json".utf8)
        try garbage.write(to: store.dataURL)

        #expect(throws: CounterStore.StoreError.malformedData) { try store.read() }
        #expect(throws: CounterStore.StoreError.malformedData) { try store.increment(tile: .alpha, writer: nil) }
        #expect(try Data(contentsOf: store.dataURL) == garbage)
    }

    @Test func storedFormatUsesStableTileNames() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        let json = #"{"lastTapAt":"2026-10-06T12:00:00Z","lastTile":"alpha","lastWriter":"w","tapsByTile":{"alpha":4,"bravo":1},"total":5}"#
        try Data(json.utf8).write(to: store.dataURL)

        let snapshot = try store.read()
        #expect(snapshot.total == 5)
        #expect(snapshot.taps(for: .alpha) == 4)
        #expect(snapshot.taps(for: .bravo) == 1)
        #expect(snapshot.lastTile == .alpha)
    }

    @Test func incrementLeavesOnlyTheDataAndLockFiles() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        try store.increment(tile: .alpha, writer: nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(names == [CounterStore.dataFileName, CounterStore.lockFileName].sorted())
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Suite struct CounterStoreLockFaultTests {
    @Test func unexpectedLockErrorFailsImmediatelyWithItsErrno() throws {
        let attempts = LockedCounter()
        let store = CounterStore(directory: try temporaryDirectory(), lockTimeout: .seconds(30)) { _ in
            attempts.add()
            return EBADF
        }
        #expect(throws: CounterStore.StoreError.lockUnavailable(errno: EBADF)) { try store.increment(tile: .alpha, writer: nil) }
        #expect(attempts.value == 1)
    }

    @Test func interruptedLockAttemptIsRetried() throws {
        let attempts = LockedCounter()
        let store = CounterStore(directory: try temporaryDirectory(), lockTimeout: .seconds(30)) { descriptor in
            attempts.add()
            return attempts.value == 1 ? EINTR : (flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? 0 : errno)
        }
        #expect(try store.increment(tile: .alpha, writer: nil).total == 1)
        #expect(attempts.value == 2)
    }
}
