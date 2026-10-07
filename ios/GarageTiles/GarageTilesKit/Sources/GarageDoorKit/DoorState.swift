import Foundation

/** A garage door's state normalized from myQ's `door_state`; anything unrecognized is unknown, never a terminal state. */
public enum DoorState: String, CaseIterable, Codable, Sendable {
    case open
    case closed
    case opening
    case closing
    case stopped
    case unknown

    public init(myQ raw: String?) {
        guard let raw, let state = DoorState(rawValue: raw.lowercased()), state != .unknown else {
            self = .unknown
            return
        }
        self = state
    }

    public var isTerminal: Bool { self == .open || self == .closed }

    public var isMoving: Bool { self == .opening || self == .closing }

    public var label: String {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .opening: "Opening"
        case .closing: "Closing"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }
}
