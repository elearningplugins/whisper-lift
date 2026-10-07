import Foundation

public enum DoorAction: String, Codable, Sendable {
    case open
    case close

    /** The terminal state this action is meant to reach. */
    public var target: DoorState { self == .open ? .open : .closed }
}

/** What the user asked for: explicit Siri open or close, or a widget toggle. */
public enum DoorRequest: Sendable, CustomStringConvertible {
    case open
    case close
    case toggle

    public var description: String {
        switch self {
        case .open: "open"
        case .close: "close"
        case .toggle: "toggle"
        }
    }
}

/** The result of looking up one door by account ID and serial in a live device list. */
public enum LiveLookup: Sendable {
    case found(DoorDevice)
    case missing
    case duplicated
    case fetchFailed
}

public enum Refusal: Equatable, Sendable {
    case missing
    case duplicated
    case liveStateUnavailable
    case notGarageDoor
    case offline
    case inFlight
    case coolingDown(until: Date)
    case fault
    case vacationMode
    case unattendedNotAllowed(DoorAction)
    case moving(DoorState)
    case stopped
    case unknownState
    case commandStateUnavailable
    case unreadableSafetyData
}

public enum CommandDecision: Equatable, Sendable {
    case send(DoorAction)
    case alreadySatisfied(DoorState)
    case refuse(Refusal)
}

/** Decides from live state whether one command may be sent; it never inverts an explicit request and never acts on a non-terminal state. */
public struct SafetyPolicy: Sendable {
    public let cooldown: TimeInterval

    public init(cooldown: TimeInterval = 15) {
        self.cooldown = cooldown
    }

    public func decide(_ request: DoorRequest, lookup: LiveLookup, inFlight: Bool, lastCommandAt: Date?, now: Date) -> CommandDecision {
        let door: DoorDevice
        switch lookup {
        case .found(let found): door = found
        case .missing: return .refuse(.missing)
        case .duplicated: return .refuse(.duplicated)
        case .fetchFailed: return .refuse(.liveStateUnavailable)
        }
        guard door.isGarageDoor else { return .refuse(.notGarageDoor) }
        guard door.online == true else { return .refuse(.offline) }

        let action: DoorAction
        switch (request, door.state) {
        case (.open, .open), (.close, .closed): return .alreadySatisfied(door.state)
        case (.open, .closed), (.toggle, .closed): action = .open
        case (.close, .open), (.toggle, .open): action = .close
        case (_, .opening), (_, .closing): return .refuse(.moving(door.state))
        case (_, .stopped): return .refuse(.stopped)
        case (.open, _), (.close, _), (.toggle, _): return .refuse(.unknownState)
        }

        guard !inFlight else { return .refuse(.inFlight) }
        if let lastCommandAt, now < lastCommandAt.addingTimeInterval(cooldown) {
            return .refuse(.coolingDown(until: lastCommandAt.addingTimeInterval(cooldown)))
        }
        guard door.unreadableSafetyFields.isEmpty else { return .refuse(.unreadableSafetyData) }
        guard door.activeFaults.isEmpty else { return .refuse(.fault) }
        if action == .open, door.vacationMode == true { return .refuse(.vacationMode) }
        let allowed = action == .open ? door.unattendedOpenAllowed : door.unattendedCloseAllowed
        guard allowed == true else { return .refuse(.unattendedNotAllowed(action)) }
        return .send(action)
    }
}
