import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

func makeSnapshot(_ state: DoorState = .closed, online: Bool? = true, fetchedAgo: TimeInterval = 0, problem: DoorProblem? = nil, serial: String = "door-1") -> DoorSnapshot {
    DoorSnapshot(
        device: makeDoor(state, online: online).with(serial: serial),
        fetchedAt: now.addingTimeInterval(-fetchedAgo),
        lastCommand: nil,
        lastCommandAt: nil,
        problem: problem
    )
}

extension DoorDevice {
    func with(serial: String) -> DoorDevice {
        DoorDevice(
            identity: DoorIdentity(accountID: identity.accountID, serial: serial), accountName: accountName, name: name, family: family, state: state,
            online: online, unattendedOpenAllowed: unattendedOpenAllowed, unattendedCloseAllowed: unattendedCloseAllowed, vacationMode: vacationMode,
            activeFaults: activeFaults, lastServerUpdate: lastServerUpdate
        )
    }
}

@Suite struct DoorSnapshotStoreTests {
    private func store() throws -> DoorSnapshotStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Doors-\(UUID().uuidString)", isDirectory: true)
        return DoorSnapshotStore(directory: directory)
    }

    @Test func emptyBeforeFirstWrite() throws {
        #expect(try store().read() == [])
    }

    @Test func upsertReplacesOnlyTheSameDoor() throws {
        let store = try store()
        try store.upsert(makeSnapshot(.closed, serial: "a"))
        try store.upsert(makeSnapshot(.open, serial: "b"))
        try store.upsert(makeSnapshot(.opening, serial: "a"))
        let saved = try store.read()
        #expect(saved.map(\.device.identity.serial) == ["a", "b"])
        #expect(saved.map(\.device.state) == [.opening, .open])
    }

    @Test func roundTripsEveryField() throws {
        let store = try store()
        let snapshot = DoorSnapshot(device: makeDoor(.open, faults: ["E2"]), fetchedAt: now, lastCommand: .close, lastCommandAt: now, problem: .uncertainCommand)
        try store.upsert(snapshot)
        #expect(try store.read() == [snapshot])
        #expect(try store.snapshot(for: snapshot.device.identity) == snapshot)
        #expect(try store.snapshot(for: DoorIdentity(accountID: "x", serial: "y")) == nil)
    }

    @Test func malformedFileIsReportedAndNotOverwritten() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: store.dataURL)
        #expect(throws: DoorSnapshotStore.StoreError.malformedData) { try store.read() }
        #expect(throws: DoorSnapshotStore.StoreError.malformedData) { try store.upsert(makeSnapshot()) }
        #expect(try Data(contentsOf: store.dataURL) == Data("garbage".utf8))
    }

    @Test func timesOutWhileAnotherProcessHoldsTheLock() throws {
        let store = DoorSnapshotStore(directory: try store().directory, lockTimeout: .milliseconds(50))
        try store.upsert(makeSnapshot(.closed))
        let holder = open(store.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: DoorSnapshotStore.StoreError.lockTimedOut) { try store.upsert(makeSnapshot(.open)) }
        #expect(try store.read().map(\.device.state) == [.closed])
        flock(holder, LOCK_UN)
        try store.upsert(makeSnapshot(.open))
        #expect(try store.read().map(\.device.state) == [.open])
    }

    @Test func concurrentUpsertsFromIndependentInstancesKeepEveryDoor() throws {
        let directory = try store().directory
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do { try DoorSnapshotStore(directory: directory, lockTimeout: .seconds(30)).upsert(makeSnapshot(serial: "door-\(index)")) } catch { failures.add() }
        }
        #expect(failures.value == 0)
        #expect(Set(try DoorSnapshotStore(directory: directory).read().map(\.device.identity.serial)) == Set((0..<12).map { "door-\($0)" }))
    }

    @Test func unexpectedLockErrorFailsImmediately() throws {
        let attempts = Counter()
        let store = DoorSnapshotStore(directory: try store().directory, lockTimeout: .seconds(30)) { _ in
            attempts.add()
            return EBADF
        }
        #expect(throws: DoorSnapshotStore.StoreError.lockUnavailable) { try store.upsert(makeSnapshot()) }
        #expect(attempts.value == 1)
    }

    @Test func interruptedLockAttemptIsRetried() throws {
        let attempts = Counter()
        let store = DoorSnapshotStore(directory: try store().directory, lockTimeout: .seconds(30)) { descriptor in
            attempts.add()
            return attempts.value == 1 ? EINTR : (flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? 0 : errno)
        }
        try store.upsert(makeSnapshot())
        #expect(attempts.value == 2)
    }

    @Test func snapshotsNeverContainTokens() throws {
        let data = try JSONEncoder().encode(makeSnapshot(problem: .signInRequired))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        #expect(!text.contains("token"))
        #expect(!text.contains("authorization"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Suite struct TilePresentationTests {
    private func tile(_ snapshot: DoorSnapshot?) -> TilePresentation {
        TilePresentation(snapshot: snapshot, now: now, staleAfter: 300)
    }

    @Test func freshTerminalStates() {
        #expect(tile(makeSnapshot(.open)) == TilePresentation(title: "Big", status: "Open", symbol: "door.garage.open", isStale: false, age: "just now", action: .close))
        #expect(tile(makeSnapshot(.closed)) == TilePresentation(title: "Big", status: "Closed", symbol: "door.garage.closed", isStale: false, age: "just now", action: .open))
    }

    @Test func nonTerminalStatesOfferNoAction() {
        for state in [DoorState.opening, .closing, .stopped, .unknown] {
            #expect(tile(makeSnapshot(state)).action == nil)
            #expect(tile(makeSnapshot(state)).status == state.label)
        }
        #expect(tile(makeSnapshot(.opening)).symbol == "door.garage.double.bay.open")
        #expect(tile(makeSnapshot(.stopped)).symbol == "exclamationmark.triangle")
    }

    @Test func problemsOverrideTheState() {
        #expect(tile(makeSnapshot(.open, problem: .signInRequired)).status == "Sign In Again")
        #expect(tile(makeSnapshot(.open, problem: .signInRequired)).action == nil)
        #expect(tile(makeSnapshot(.open, online: false)).status == "Offline")
        #expect(tile(makeSnapshot(.open, online: false)).action == nil)
        #expect(tile(makeSnapshot(.open, problem: .uncertainCommand)).status == "Check Door")
    }

    @Test func noSnapshotAsksForSetup() {
        #expect(tile(nil) == TilePresentation(title: "Garage", status: "Set Up", symbol: "questionmark.square.dashed", isStale: true, age: nil, action: nil))
    }

    @Test(arguments: [(0.0, "just now"), (59, "just now"), (60, "1m ago"), (3599, "59m ago"), (3600, "1h ago"), (86_399, "23h ago"), (86_400, "1d ago")])
    func ageText(_ seconds: TimeInterval, _ expected: String) {
        #expect(tile(makeSnapshot(fetchedAgo: seconds)).age == expected)
    }

    @Test func staleExactlyAtTheThreshold() {
        #expect(tile(makeSnapshot(fetchedAgo: 299.999)).isStale == false)
        #expect(tile(makeSnapshot(fetchedAgo: 300)).isStale == true)
    }

    @Test func staleStateIsNeverPresentedAsConfirmed() {
        let stale = tile(makeSnapshot(.open, fetchedAgo: 600))
        #expect(stale.isStale)
        #expect(stale.status == "Open")
        #expect(stale.age == "10m ago")
    }

    @Test func futureFetchTimesAreTreatedAsJustNow() {
        #expect(tile(makeSnapshot(fetchedAgo: -30)).age == "just now")
        #expect(tile(makeSnapshot(fetchedAgo: -30)).isStale == false)
    }

    @Test func actionOnlyEverMovesAwayFromAConfirmedOnlineState() {
        forAll(iterations: 1000, { rng in
            (DoorState.allCases.randomElement(using: &rng)!, [true, false, nil].randomElement(using: &rng)!,
             [nil, DoorProblem.signInRequired, .uncertainCommand, .unreachable, .rateLimited].randomElement(using: &rng)!,
             Double.random(in: -100...10_000, using: &rng))
        }) { state, online, problem, age in
            let presented = tile(makeSnapshot(state, online: online, fetchedAgo: age, problem: problem))
            guard let action = presented.action else { return true }
            return online == true && problem == nil && ((state == .closed && action == .open) || (state == .open && action == .close))
        }
    }
}

@Suite struct SnapshotCompatibilityTests {
    // A doors.json written before unreadableSafetyFields existed must still load, or every command would be refused.
    @Test func snapshotsWithoutTheNewSafetyFieldStillDecode() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode([makeSnapshot(.closed)])) as? [[String: Any]])
        var device = try #require(object[0]["device"] as? [String: Any])
        device.removeValue(forKey: "unreadableSafetyFields")
        object[0]["device"] = device
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Compat-\(UUID().uuidString)", isDirectory: true)
        let store = DoorSnapshotStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: store.dataURL)
        let loaded = try store.read()
        #expect(loaded.count == 1)
        #expect(loaded[0].device.unreadableSafetyFields == [])
        #expect(loaded[0].device.state == .closed)
    }

    @Test func unreadableSafetyFieldsRoundTrip() throws {
        let device = makeDoor(.closed).with(serial: "s")
        let flagged = DoorDevice(
            identity: device.identity, accountName: "Home", name: "Big", family: "garagedoor", state: .closed, online: true, unattendedOpenAllowed: true,
            unattendedCloseAllowed: true, vacationMode: nil, activeFaults: [], lastServerUpdate: nil, unreadableSafetyFields: ["in_vacation_mode"]
        )
        let decoded = try JSONDecoder().decode(DoorDevice.self, from: JSONEncoder().encode(flagged))
        #expect(decoded == flagged)
    }
}
