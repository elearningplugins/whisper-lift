import Foundation
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let identity = DoorIdentity(accountID: "account-1", serial: "door-1")

private func lockDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CommandLock-\(UUID().uuidString)", isDirectory: true)
}

final class FailingSnapshots: SnapshotStoring, @unchecked Sendable {
    var failReads = false
    var failWrites = false
    private let inner = MemorySnapshots()

    func snapshot(for identity: DoorIdentity) throws -> DoorSnapshot? {
        if failReads { throw DoorSnapshotStore.StoreError.malformedData }
        return try inner.snapshot(for: identity)
    }

    func upsert(_ snapshot: DoorSnapshot) throws {
        if failWrites { throw DoorSnapshotStore.StoreError.writeFailed }
        try inner.upsert(snapshot)
    }
}

private func service(_ api: FakeDoorAPI, _ snapshots: any SnapshotStoring, lock: any CommandLocking) -> DoorCommandService {
    DoorCommandService(
        api: api, snapshots: snapshots, commandLock: lock, policy: SafetyPolicy(cooldown: 15), followUpReads: 0,
        followUpInterval: .seconds(3), now: { now }, sleep: { _ in }
    )
}

@Suite struct CrossProcessCommandTests {
    // Siri and the app run separate services; the shared per-door lock and the recorded command keep it to one PUT.
    @Test func twoSeparateServicesSendOneCommand() async {
        let api = FakeDoorAPI(states: [.closed, .closed, .closed, .closed])
        api.commandDelay = .milliseconds(150)
        let snapshots = MemorySnapshots()
        let directory = lockDirectory()
        let siri = service(api, snapshots, lock: FileCommandLock(directory: directory, timeout: .seconds(5)))
        let app = service(api, snapshots, lock: FileCommandLock(directory: directory, timeout: .seconds(5)))
        async let first = siri.perform(.toggle, on: identity, accountName: "Home")
        async let second = app.perform(.toggle, on: identity, accountName: "Home")
        let outcomes = await [first, second]
        #expect(api.commands == [.open])
        #expect(outcomes.contains(.refused(.coolingDown(until: now.addingTimeInterval(15)))) || outcomes.contains(.refused(.inFlight)))
    }

    @Test func busyLockRefusesAsInFlightWithoutReadingMyQ() async throws {
        let directory = lockDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let holder = open(FileCommandLock(directory: directory).url(for: identity).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        let api = FakeDoorAPI(states: [.closed])
        let outcome = await service(api, MemorySnapshots(), lock: FileCommandLock(directory: directory, timeout: .milliseconds(50))).perform(.toggle, on: identity, accountName: "Home")
        #expect(outcome == .refused(.inFlight))
        #expect(api.readCount == 0)
        #expect(api.commands.isEmpty)
    }

    @Test func lockFileNamesDoNotContainTheSerial() {
        let url = FileCommandLock(directory: lockDirectory()).url(for: DoorIdentity(accountID: "acc/1", serial: "SERIAL-1"))
        #expect(!url.lastPathComponent.contains("SERIAL"))
        #expect(!url.lastPathComponent.contains("/"))
        #expect(url.lastPathComponent.hasSuffix(".lock"))
        #expect(FileCommandLock(directory: lockDirectory()).url(for: identity).lastPathComponent != url.lastPathComponent)
    }

    @Test func unreadableCommandStateRefusesWithoutSending() async {
        let snapshots = FailingSnapshots()
        snapshots.failReads = true
        let api = FakeDoorAPI(states: [.closed])
        let outcome = await service(api, snapshots, lock: FileCommandLock(directory: lockDirectory())).perform(.toggle, on: identity, accountName: "Home")
        #expect(outcome == .refused(.commandStateUnavailable))
        #expect(api.commands.isEmpty)
    }

    @Test func commandIsRecordedBeforeItIsSent() async throws {
        let snapshots = MemorySnapshots()
        let api = FakeDoorAPI(states: [.closed])
        _ = await service(api, snapshots, lock: FileCommandLock(directory: lockDirectory())).perform(.open, on: identity, accountName: "Home")
        let recorded = try #require(snapshots.history.first { $0.lastCommand == .open })
        #expect(recorded.lastCommandAt == now)
        #expect(snapshots.history.firstIndex { $0.lastCommand == .open } ?? 99 < 2)
    }

    // If the process dies after myQ accepts the PUT but before the moving state is saved, the tile must not show a stale terminal state as actionable.
    @Test func commandIsRecordedAsUncertainUntilMyQAnswers() async throws {
        let snapshots = MemorySnapshots()
        let api = FakeDoorAPI(states: [.closed])
        _ = await service(api, snapshots, lock: FileCommandLock(directory: lockDirectory())).perform(.open, on: identity, accountName: "Home")
        let recorded = try #require(snapshots.history.first { $0.lastCommand == .open })
        #expect(recorded.problem == .uncertainCommand)
        let tile = TilePresentation(snapshot: recorded, now: now)
        #expect(tile.status == "Check Door")
        #expect(tile.action == nil)
        #expect(snapshots.history.last?.problem == nil)
        #expect(snapshots.history.last?.device.state == .opening)
    }

    @Test func unrecordableCommandIsNotSent() async {
        let snapshots = FailingSnapshots()
        snapshots.failWrites = true
        let api = FakeDoorAPI(states: [.closed])
        let outcome = await service(api, snapshots, lock: FileCommandLock(directory: lockDirectory())).perform(.open, on: identity, accountName: "Home")
        #expect(outcome == .refused(.commandStateUnavailable))
        #expect(api.commands.isEmpty)
    }

    @Test func commandStateDialog() {
        #expect(CommandOutcome.refused(.commandStateUnavailable).dialog(doorName: "Big") == "Whisper Lift couldn't safely record the command, so I didn't move Big. Try again.")
    }
}
