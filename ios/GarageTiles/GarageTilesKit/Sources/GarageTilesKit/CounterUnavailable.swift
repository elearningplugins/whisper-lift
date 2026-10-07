import Foundation

/** Why the shared counter could not be used, so a misconfigured App Group is never reported as a locked phone. */
public enum CounterUnavailable: CaseIterable, Equatable, Sendable {
    case appGroupMissing
    case protectedData
    case busy
    case damaged
    case unexpected

    public init(_ error: any Error) {
        switch error {
        case is AppGroup.ResolutionError:
            self = .appGroupMissing
        case CounterStore.StoreError.unreadable:
            self = .protectedData
        case CounterStore.StoreError.lockUnavailable(let code) where code == EPERM || code == EACCES:
            self = .protectedData
        case CounterStore.StoreError.lockTimedOut:
            self = .busy
        case CounterStore.StoreError.malformedData:
            self = .damaged
        default:
            self = .unexpected
        }
    }

    public var headline: String {
        switch self {
        case .appGroupMissing: "App Group missing"
        case .protectedData: "Unlock iPhone"
        case .busy: "Busy, tap again"
        case .damaged: "Counter damaged"
        case .unexpected: "Counter unavailable"
        }
    }

    public var guidance: String {
        switch self {
        case .appGroupMissing: "Both targets need the same App Group. Check Signing & Capabilities."
        case .protectedData: "Unlock the iPhone once after restarting, then try again."
        case .busy: "Another tap was still saving. Try again."
        case .damaged: "The counter file is unreadable. Delete and reinstall the app to reset it."
        case .unexpected: "Open Whisper Lift for details."
        }
    }
}
