import Foundation

/** Skips a status check that would repeat one made moments ago, as when opening the app fires both appear and become-active; a forced check always runs. */
public struct CheckThrottle: Sendable {
    public let minimumInterval: TimeInterval
    private var lastCheck: Date?

    public init(minimumInterval: TimeInterval = 5) {
        self.minimumInterval = minimumInterval
    }

    public mutating func allow(at now: Date, force: Bool = false) -> Bool {
        if !force, let lastCheck, now.timeIntervalSince(lastCheck) < minimumInterval { return false }
        lastCheck = now
        return true
    }
}
