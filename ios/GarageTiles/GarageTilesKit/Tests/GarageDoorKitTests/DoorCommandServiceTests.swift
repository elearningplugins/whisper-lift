import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let identity = DoorIdentity(accountID: "account-1", serial: "door-1")

/** A fake myQ whose successive device reads return the given states; it records every command. */
final class FakeDoorAPI: DoorAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Result<[DoorDevice], any Error>]
    private(set) var commands: [DoorAction] = []
    private(set) var readCount = 0
    var commandResult: Result<Void, any Error> = .success(())
    var commandDelay: Duration = .zero

    init(_ reads: [Result<[DoorDevice], any Error>]) {
        self.reads = reads
    }

    convenience init(states: [DoorState]) {
        self.init(states.map { .success([makeDoor($0)]) })
    }

    func devices(in account: MyQAccount) async throws -> [DoorDevice] {
        let next: Result<[DoorDevice], any Error> = lock.withLock {
            readCount += 1
            return reads.isEmpty ? .failure(MyQError.transport) : reads.removeFirst()
        }
        return try next.get()
    }

    func send(_ action: DoorAction, to door: DoorIdentity) async throws {
        lock.withLock { commands.append(action) }
        if commandDelay > .zero { try await Task.sleep(for: commandDelay) }
        try commandResult.get()
    }
}

final class MemorySnapshots: SnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var history: [DoorSnapshot] = []
    private var current: [DoorIdentity: DoorSnapshot] = [:]

    init(_ initial: [DoorSnapshot] = []) {
        for snapshot in initial { current[snapshot.device.identity] = snapshot }
    }

    func snapshot(for identity: DoorIdentity) throws -> DoorSnapshot? {
        lock.withLock { current[identity] }
    }

    func upsert(_ snapshot: DoorSnapshot) throws {
        lock.withLock {
            current[snapshot.device.identity] = snapshot
            history.append(snapshot)
        }
    }
}

private func service(_ api: FakeDoorAPI, _ snapshots: MemorySnapshots = MemorySnapshots(), followUps: Int = 3) -> DoorCommandService {
    DoorCommandService(
        api: api, snapshots: snapshots, commandLock: FileCommandLock(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Locks-\(UUID().uuidString)")),
        policy: SafetyPolicy(cooldown: 15), followUpReads: followUps, followUpInterval: .seconds(3), now: { now }, sleep: { _ in }
    )
}

@Suite struct DoorCommandServiceTests {
    @Test func toggleSendsOnceSavesOptimisticStateAndConfirms() async {
        let api = FakeDoorAPI(states: [.closed, .opening, .open])
        let snapshots = MemorySnapshots()
        let outcome = await service(api, snapshots).perform(.toggle, on: identity, accountName: "Home")
        #expect(outcome == .completed(.open))
        #expect(api.commands == [.open])
        #expect(api.readCount == 3)
        // Live read, the command recorded before sending, the optimistic state, then two follow-up reads.
        #expect(snapshots.history.map(\.device.state) == [.closed, .closed, .opening, .opening, .open])
        #expect(snapshots.history[1].lastCommand == .open)
        #expect(snapshots.history[1].lastCommandAt == now)
        #expect(snapshots.history.last?.lastCommand == .open)
        #expect(snapshots.history.last?.problem == nil)
    }

    @Test func unconfirmedAcceptanceStaysProvisionalAfterBoundedReads() async {
        let api = FakeDoorAPI(states: [.open, .open, .closing, .closing, .closing])
        let outcome = await service(api, followUps: 3).perform(.close, on: identity, accountName: "Home")
        #expect(outcome == .accepted(lastObserved: .closing))
        #expect(api.commands == [.close])
        #expect(api.readCount == 4)
    }

    @Test func followUpReadFailuresDoNotResend() async {
        let api = FakeDoorAPI([.success([makeDoor(.open)]), .failure(MyQError.transport), .failure(MyQError.transport), .failure(MyQError.transport)])
        let outcome = await service(api).perform(.close, on: identity, accountName: "Home")
        #expect(outcome == .accepted(lastObserved: .closing))
        #expect(api.commands == [.close])
    }

    @Test func uncertainOutcomeIsReadOnceAndNeverResent() async {
        let api = FakeDoorAPI(states: [.closed, .opening])
        api.commandResult = .failure(CommandError.outcomeUnknown)
        let snapshots = MemorySnapshots()
        let outcome = await service(api, snapshots).perform(.open, on: identity, accountName: "Home")
        #expect(outcome == .uncertain(observed: .opening))
        #expect(api.commands == [.open])
        #expect(api.readCount == 2)
        #expect(snapshots.history.last?.problem == .uncertainCommand)
        #expect(snapshots.history.last?.lastCommandAt == now)
    }

    @Test func uncertainOutcomeWithAFailedReReadReportsNoState() async {
        let api = FakeDoorAPI([.success([makeDoor(.closed)]), .failure(MyQError.transport)])
        api.commandResult = .failure(CommandError.outcomeUnknown)
        #expect(await service(api).perform(.open, on: identity, accountName: "Home") == .uncertain(observed: nil))
        #expect(api.commands == [.open])
    }

    @Test func explicitRequestAlreadySatisfiedSendsNothing() async {
        let api = FakeDoorAPI(states: [.open])
        #expect(await service(api).perform(.open, on: identity, accountName: "Home") == .alreadySatisfied(.open))
        #expect(api.commands.isEmpty)
    }

    @Test func refusalSendsNothingButCachesTheLiveState() async {
        let api = FakeDoorAPI(states: [.opening])
        let snapshots = MemorySnapshots()
        #expect(await service(api, snapshots).perform(.toggle, on: identity, accountName: "Home") == .refused(.moving(.opening)))
        #expect(api.commands.isEmpty)
        #expect(snapshots.history.map(\.device.state) == [.opening])
    }

    @Test func missingAndDuplicatedDoorsAreRefused() async {
        let other = makeDoor(.closed).with(serial: "other")
        #expect(await service(FakeDoorAPI([.success([other])])).perform(.toggle, on: identity, accountName: "Home") == .refused(.missing))
        #expect(await service(FakeDoorAPI([.success([makeDoor(.closed), makeDoor(.closed)])])).perform(.toggle, on: identity, accountName: "Home") == .refused(.duplicated))
    }

    @Test func failedLiveReadRefusesAndMarksTheCacheUnreachable() async {
        let cached = makeSnapshot(.closed)
        let snapshots = MemorySnapshots([cached])
        let api = FakeDoorAPI([.failure(MyQError.transport)])
        #expect(await service(api, snapshots).perform(.toggle, on: identity, accountName: "Home") == .refused(.liveStateUnavailable))
        #expect(api.commands.isEmpty)
        #expect(snapshots.history.last?.problem == .unreachable)
        #expect(snapshots.history.last?.device.state == .closed)
        #expect(snapshots.history.last?.fetchedAt == cached.fetchedAt)
    }

    @Test func signInAndRateLimitAreReportedWithoutSending() async {
        let snapshots = MemorySnapshots([makeSnapshot(.closed)])
        #expect(await service(FakeDoorAPI([.failure(TokenError.signInRequired)]), snapshots).perform(.toggle, on: identity, accountName: "Home") == .signInRequired)
        #expect(snapshots.history.last?.problem == .signInRequired)
        #expect(await service(FakeDoorAPI([.failure(MyQError.rateLimited(retryAfter: 30))])).perform(.toggle, on: identity, accountName: "Home") == .rateLimited)
    }

    @Test func tokenFailureAtSendTimeMeansNothingWasSent() async {
        let api = FakeDoorAPI(states: [.closed])
        api.commandResult = .failure(TokenError.signInRequired)
        let snapshots = MemorySnapshots()
        #expect(await service(api, snapshots).perform(.open, on: identity, accountName: "Home") == .signInRequired)
        // The uncertain pre-send record is replaced, since no command left the phone.
        #expect(snapshots.history.last?.problem == .signInRequired)
        #expect(snapshots.history.last?.lastCommand == nil)
    }

    @Test func recentCommandFromAnotherProcessCoolsDown() async {
        var recent = makeSnapshot(.closed)
        recent = DoorSnapshot(device: recent.device, fetchedAt: now, lastCommand: .open, lastCommandAt: now.addingTimeInterval(-5), problem: nil)
        let api = FakeDoorAPI(states: [.closed])
        #expect(await service(api, MemorySnapshots([recent])).perform(.toggle, on: identity, accountName: "Home") == .refused(.coolingDown(until: now.addingTimeInterval(10))))
        #expect(api.commands.isEmpty)
    }

    @Test func doubleTapSendsOneCommand() async {
        let api = FakeDoorAPI(states: [.closed, .closed, .open, .open, .open, .open])
        api.commandDelay = .milliseconds(50)
        let shared = service(api, followUps: 1)
        async let first = shared.perform(.toggle, on: identity, accountName: "Home")
        async let second = shared.perform(.toggle, on: identity, accountName: "Home")
        let outcomes = await [first, second]
        #expect(api.commands == [.open])
        #expect(outcomes.contains(.refused(.inFlight)) || outcomes.contains(.refused(.coolingDown(until: now.addingTimeInterval(15)))))
    }

    @Test func atMostOneCommandPerTapAndExplicitRequestsAreNeverInverted() async {
        await forAllAsync(iterations: 300, { rng in
            ([DoorRequest.open, .close, .toggle].randomElement(using: &rng)!,
             (0..<5).map { _ in DoorState.allCases.randomElement(using: &rng)! },
             Bool.random(using: &rng))
        }) { request, states, uncertain in
            let api = FakeDoorAPI(states: states)
            if uncertain { api.commandResult = .failure(CommandError.outcomeUnknown) }
            _ = await service(api).perform(request, on: identity, accountName: "Home")
            let commands = api.commands
            guard let action = commands.first else { return true }
            guard commands.count == 1 else { return false }
            switch request {
            case .open: return action == .open
            case .close: return action == .close
            case .toggle: return action.target != states[0]
            }
        }
    }
}

@Suite struct CommandOutcomeDialogTests {
    @Test func spokenDialogForEveryOutcome() {
        let cases: [(CommandOutcome, String)] = [
            (.completed(.open), "Big is open."),
            (.accepted(lastObserved: .closing), "Big is closing."),
            (.alreadySatisfied(.closed), "Big is already closed."),
            (.uncertain(observed: .opening), "I'm not sure the command reached Big. myQ now reports it as opening. Check the door."),
            (.uncertain(observed: nil), "I'm not sure the command reached Big. Check the door."),
            (.refused(.moving(.opening)), "Big is opening. Try again when it stops."),
            (.refused(.offline), "Big is offline."),
            (.refused(.liveStateUnavailable), "I couldn't reach myQ, so I didn't move Big."),
            (.refused(.inFlight), "A command for Big is already in progress."),
            (.refused(.coolingDown(until: now)), "Big was just moved. Wait a moment."),
            (.refused(.stopped), "Big is stopped. Check the door."),
            (.refused(.unknownState), "I don't know Big's state, so I didn't move it."),
            (.refused(.fault), "Big reports a fault."),
            (.refused(.vacationMode), "Big is in vacation mode."),
            (.refused(.unattendedNotAllowed(.open)), "myQ doesn't allow opening Big remotely."),
            (.refused(.unattendedNotAllowed(.close)), "myQ doesn't allow closing Big remotely."),
            (.refused(.missing), "I couldn't find Big. Open Whisper Lift to set it up again."),
            (.refused(.duplicated), "I found more than one Big. Open Whisper Lift to set it up again."),
            (.refused(.notGarageDoor), "Big isn't a garage door."),
            (.signInRequired, "Open Whisper Lift and sign in again."),
            (.rateLimited, "myQ is busy. Try again in a minute."),
            (.unavailable, "Whisper Lift couldn't read its saved session. Try again."),
        ]
        for (outcome, expected) in cases {
            #expect(outcome.dialog(doorName: "Big") == expected)
        }
    }
}
