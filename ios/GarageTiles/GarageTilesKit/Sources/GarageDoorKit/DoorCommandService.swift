import Foundation

/** The myQ operations the command service needs; MyQClient is the production implementation. */
public protocol DoorAPI: Sendable {
    func devices(in account: MyQAccount) async throws -> [DoorDevice]
    func send(_ action: DoorAction, to door: DoorIdentity) async throws
}

extension MyQClient: DoorAPI {}

public enum CommandOutcome: Equatable, Sendable {
    case completed(DoorState)
    case accepted(lastObserved: DoorState)
    case alreadySatisfied(DoorState)
    case uncertain(observed: DoorState?)
    case refused(Refusal)
    case signInRequired
    case rateLimited
    case unavailable

    /** A short sentence for Siri and the widget's intent result. */
    public func dialog(doorName name: String) -> String {
        switch self {
        case .completed(let state), .accepted(let state): "\(name) is \(state.rawValue)."
        case .alreadySatisfied(let state): "\(name) is already \(state.rawValue)."
        case .uncertain(let state?): "I'm not sure the command reached \(name). myQ now reports it as \(state.rawValue). Check the door."
        case .uncertain(nil): "I'm not sure the command reached \(name). Check the door."
        case .refused(let refusal): Self.dialog(for: refusal, name: name)
        case .signInRequired: "Open Whisper Lift and sign in again."
        case .rateLimited: "myQ is busy. Try again in a minute."
        case .unavailable: "Whisper Lift couldn't read its saved session. Try again."
        }
    }

    private static func dialog(for refusal: Refusal, name: String) -> String {
        return switch refusal {
        case .moving(let state): "\(name) is \(state.rawValue). Try again when it stops."
        case .offline: "\(name) is offline."
        case .liveStateUnavailable: "I couldn't reach myQ, so I didn't move \(name)."
        case .inFlight: "A command for \(name) is already in progress."
        case .coolingDown: "\(name) was just moved. Wait a moment."
        case .stopped: "\(name) is stopped. Check the door."
        case .unknownState: "I don't know \(name)'s state, so I didn't move it."
        case .fault: "\(name) reports a fault."
        case .vacationMode: "\(name) is in vacation mode."
        case .unattendedNotAllowed(let action): "myQ doesn't allow \(action == .open ? "opening" : "closing") \(name) remotely."
        case .missing: "I couldn't find \(name). Open Whisper Lift to set it up again."
        case .duplicated: "I found more than one \(name). Open Whisper Lift to set it up again."
        case .notGarageDoor: "\(name) isn't a garage door."
        case .commandStateUnavailable: "Whisper Lift couldn't safely record the command, so I didn't move \(name). Try again."
        case .unreadableSafetyData: "myQ sent safety information for \(name) that I couldn't read, so I didn't move it."
        }
    }
}

/** Runs one tap or Siri request: live read, safety policy, at most one command, optimistic snapshot, bounded follow-up reads (PLAN.md Phase 8). */
public actor DoorCommandService {
    let api: any DoorAPI
    let snapshots: any SnapshotStoring
    let commandLock: any CommandLocking
    let policy: SafetyPolicy
    let followUpReads: Int
    let followUpInterval: Duration
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async -> Void
    private var inFlight: Set<DoorIdentity> = []

    public init(
        api: any DoorAPI,
        snapshots: any SnapshotStoring,
        commandLock: any CommandLocking,
        policy: SafetyPolicy = SafetyPolicy(),
        followUpReads: Int = 3,
        followUpInterval: Duration = .seconds(3),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.api = api
        self.snapshots = snapshots
        self.commandLock = commandLock
        self.policy = policy
        self.followUpReads = followUpReads
        self.followUpInterval = followUpInterval
        self.now = now
        self.sleep = sleep
    }

    /** Holds the door's interprocess command lock for the whole request; a busy lock means another tap or Siri request is already acting. */
    public func perform(_ request: DoorRequest, on door: DoorIdentity, accountName: String) async -> CommandOutcome {
        do {
            return try await commandLock.withDoorLock(door) { await self.performLocked(request, on: door, accountName: accountName) }
        } catch CommandLockError.busy {
            return .refused(.inFlight)
        } catch {
            return .refused(.commandStateUnavailable)
        }
    }

    private func performLocked(_ request: DoorRequest, on door: DoorIdentity, accountName: String) async -> CommandOutcome {
        let account = MyQAccount(id: door.accountID, name: accountName)
        // The cached snapshot carries the cooldown; if it cannot be read, nothing is sent.
        let cached: DoorSnapshot?
        do {
            cached = try snapshots.snapshot(for: door)
        } catch {
            return .refused(.commandStateUnavailable)
        }
        let lookup: LiveLookup
        do {
            lookup = Self.lookup(door, in: try await api.devices(in: account))
        } catch TokenError.signInRequired {
            mark(cached, .signInRequired)
            return .signInRequired
        } catch MyQError.rateLimited {
            mark(cached, .rateLimited)
            return .rateLimited
        } catch {
            mark(cached, .unreachable)
            lookup = .fetchFailed
        }
        if case .found(let device) = lookup {
            save(DoorSnapshot(device: device, fetchedAt: now(), lastCommand: cached?.lastCommand, lastCommandAt: cached?.lastCommandAt, problem: nil))
        }

        let decision = policy.decide(request, lookup: lookup, inFlight: inFlight.contains(door), lastCommandAt: cached?.lastCommandAt, now: now())
        guard case .send(let action) = decision, case .found(let device) = lookup else {
            switch decision {
            case .alreadySatisfied(let state): return .alreadySatisfied(state)
            case .refuse(let refusal): return .refused(refusal)
            case .send: return .refused(.liveStateUnavailable)
            }
        }

        // Marked before the first suspension point, so an overlapping tap on this actor sees it.
        inFlight.insert(door)
        defer { inFlight.remove(door) }
        let sentAt = now()
        // Record the command as uncertain before sending: if this process dies mid-request, the cooldown holds and the tile shows Check Door, never a stale actionable state. Unrecordable means unsent.
        do {
            try snapshots.upsert(DoorSnapshot(device: device, fetchedAt: sentAt, lastCommand: action, lastCommandAt: sentAt, problem: .uncertainCommand))
        } catch {
            return .refused(.commandStateUnavailable)
        }
        do {
            try await api.send(action, to: door)
        } catch let error as TokenError {
            // The token failed before any request, so nothing was sent; restore the record as it was before this attempt.
            save(DoorSnapshot(device: device, fetchedAt: sentAt, lastCommand: cached?.lastCommand, lastCommandAt: cached?.lastCommandAt, problem: error == .signInRequired ? .signInRequired : nil))
            return error == .signInRequired ? .signInRequired : .unavailable
        } catch {
            let observed = try? Self.lookup(door, in: await api.devices(in: account))
            let latest: DoorDevice = if case .found(let fresh)? = observed { fresh } else { device }
            save(DoorSnapshot(device: latest, fetchedAt: now(), lastCommand: action, lastCommandAt: sentAt, problem: .uncertainCommand))
            if case .found(let fresh)? = observed { return .uncertain(observed: fresh.state) }
            return .uncertain(observed: nil)
        }

        var lastObserved: DoorState = action == .open ? .opening : .closing
        save(DoorSnapshot(device: device.with(state: lastObserved), fetchedAt: sentAt, lastCommand: action, lastCommandAt: sentAt, problem: nil))
        for _ in 0..<followUpReads {
            await sleep(followUpInterval)
            guard case .found(let fresh)? = try? Self.lookup(door, in: await api.devices(in: account)) else { continue }
            lastObserved = fresh.state
            save(DoorSnapshot(device: fresh, fetchedAt: now(), lastCommand: action, lastCommandAt: sentAt, problem: nil))
            if fresh.state == action.target { return .completed(fresh.state) }
        }
        return .accepted(lastObserved: lastObserved)
    }

    static func lookup(_ door: DoorIdentity, in devices: [DoorDevice]) -> LiveLookup {
        let matches = devices.filter { $0.identity == door }
        switch matches.count {
        case 0: return .missing
        case 1: return .found(matches[0])
        default: return .duplicated
        }
    }

    private func mark(_ cached: DoorSnapshot?, _ problem: DoorProblem) {
        if let cached { save(cached.marking(problem)) }
    }

    private func save(_ snapshot: DoorSnapshot) {
        try? snapshots.upsert(snapshot)
    }
}

extension DoorDevice {
    func with(state newState: DoorState) -> DoorDevice {
        DoorDevice(
            identity: identity, accountName: accountName, name: name, family: family, state: newState, online: online,
            unattendedOpenAllowed: unattendedOpenAllowed, unattendedCloseAllowed: unattendedCloseAllowed, vacationMode: vacationMode,
            activeFaults: activeFaults, lastServerUpdate: lastServerUpdate, unreadableSafetyFields: unreadableSafetyFields
        )
    }
}
