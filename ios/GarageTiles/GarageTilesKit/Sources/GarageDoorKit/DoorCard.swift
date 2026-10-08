import Foundation

/** How the Doors tab draws one door, following the app design: a color, an icon and words for every state, and what a tap on the card does. */
public struct DoorCard: Equatable, Sendable {
    /** The card's color family: red closed, green open, purple moving, amber warning outline, gray neutral outline. */
    public enum Tone: String, Sendable {
        case closed, open, moving, warning, neutral
    }

    public enum Icon: String, Sendable {
        case closed, open, opening, closing, warning, question, offline, locked, clock, signIn
    }

    /** A tap sends one explicit command, explains why it can't right now without any request, or does nothing. */
    public enum Tap: Equatable, Sendable {
        case send(DoorAction)
        case explain(String)
        case none
    }

    public static let alreadyMoving = "Already moving. Wait for it to finish."
    public static let justMoved = "Just moved. Try again in a few seconds."

    public let title: String
    public let detail: String
    public let tone: Tone
    public let icon: Icon
    public let dashedBorder: Bool
    public let tap: Tap
    public let hint: String?

    public var isProblem: Bool { tone == .warning || tone == .neutral }

    public init(title: String, detail: String, tone: Tone, icon: Icon, dashedBorder: Bool, tap: Tap, hint: String?) {
        self.title = title
        self.detail = detail
        self.tone = tone
        self.icon = icon
        self.dashedBorder = dashedBorder
        self.tap = tap
        self.hint = hint
    }

    /** Problems come first, in safety order, so a card never shows an actionable color for a door the policy would refuse. */
    public init(snapshot: DoorSnapshot?, now: Date, cooldown: TimeInterval = SafetyPolicy().cooldown, staleAfter: TimeInterval = 600) {
        guard let snapshot else {
            self = .problem("Not checked yet", "The app hasn't heard from this door yet.", .neutral, .clock, dashed: true)
            return
        }
        let device = snapshot.device
        if snapshot.problem == .signInRequired {
            self = .problem("Sign in again", "Your myQ session ended. Sign in with myQ to use this door.", .neutral, .signIn, dashed: false)
        } else if snapshot.problem == .uncertainCommand {
            self = .problem("Not sure it worked", "The command was sent, but the door didn't confirm. Please check on it.", .warning, .question, dashed: true)
        } else if device.online != true {
            self = .problem("Can't reach door", "myQ says the opener is offline. It may have lost its Wi\u{2011}Fi.", .neutral, .offline, dashed: true)
        } else if !device.unreadableSafetyFields.isEmpty {
            self = .problem("Safety status unreadable", "myQ sent safety information the app couldn't read, so it won't move this door.", .warning, .warning, dashed: false)
        } else if !device.activeFaults.isEmpty {
            self = .problem("Door has a fault", "The opener reported a problem. Check the door, then try again.", .warning, .warning, dashed: false)
        } else if device.state == .stopped {
            self = .problem("Stopped partway", "The door stopped before finishing. Check it before using the app.", .neutral, .question, dashed: false)
        } else if device.state == .unknown {
            self = .problem("Position unknown", "myQ didn't say if this door is open or closed.", .neutral, .question, dashed: true)
        } else if device.vacationMode == true {
            self = .problem("Vacation mode is on", "Turn it off in the myQ app to open this door. Closing still works.", .neutral, .locked, dashed: false)
        } else if device.unattendedOpenAllowed == false, device.unattendedCloseAllowed == false {
            self = .problem("Remote control is off", "This door doesn't allow control from an app.", .neutral, .locked, dashed: false)
        } else if snapshot.problem == .unreachable || snapshot.problem == .rateLimited || now.timeIntervalSince(snapshot.fetchedAt) >= staleAfter {
            self = Self.lastKnown(device.state, age: now.timeIntervalSince(snapshot.fetchedAt), failure: snapshot.problem)
        } else {
            self = Self.normal(device.state, updated: Self.updatedText(now.timeIntervalSince(snapshot.fetchedAt)), coolingDown: snapshot.lastCommandAt.map { now < $0.addingTimeInterval(cooldown) } ?? false)
        }
    }

    private static func problem(_ title: String, _ detail: String, _ tone: Tone, _ icon: Icon, dashed: Bool) -> DoorCard {
        DoorCard(title: title, detail: detail, tone: tone, icon: icon, dashedBorder: dashed, tap: .none, hint: nil)
    }

    // An old or unconfirmed state is shown outlined and labelled "Last known", never in the filled color of a current state.
    private static func lastKnown(_ state: DoorState, age: TimeInterval, failure: DoorProblem?) -> DoorCard {
        let checked = "Last checked " + updatedText(age).dropFirst("Updated ".count) + "."
        let detail = switch failure {
        case .unreachable?: "Couldn\u{2019}t reach myQ. " + checked
        case .rateLimited?: "myQ is busy. " + checked
        default: checked + " Pull down to check again."
        }
        let label = switch state {
        case .open: "Open"
        case .closed: "Closed"
        case .opening: "Opening\u{2026}"
        case .closing: "Closing\u{2026}"
        case .stopped, .unknown: "Unknown"
        }
        return problem(("Last known: " + label), detail, .neutral, .clock, dashed: true)
    }

    private static func normal(_ state: DoorState, updated: String, coolingDown: Bool) -> DoorCard {
        switch state {
        case .opening, .closing:
            return DoorCard(
                title: state == .opening ? "Opening\u{2026}" : "Closing\u{2026}", detail: updated, tone: .moving, icon: state == .opening ? .opening : .closing,
                dashedBorder: false, tap: .explain(alreadyMoving), hint: "Moving"
            )
        default:
            let isOpen = state == .open
            return DoorCard(
                title: isOpen ? "Open" : "Closed", detail: coolingDown ? justMoved : updated, tone: isOpen ? .open : .closed, icon: isOpen ? .open : .closed,
                dashedBorder: false, tap: coolingDown ? .explain(justMoved) : .send(isOpen ? .close : .open), hint: isOpen ? "Tap to close" : "Tap to open"
            )
        }
    }

    static func updatedText(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        switch seconds {
        case ..<60: return "Updated just now"
        case ..<3600: return "Updated \(Int(seconds / 60)) min ago"
        case ..<86_400: return "Updated \(Int(seconds / 3600)) hr ago"
        default:
            let days = Int(seconds / 86_400)
            return "Updated \(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

extension CommandOutcome {
    /** The short line under a card after a tap; nil when the card's new state already says it. */
    public func cardMessage(doorName name: String) -> String? {
        switch self {
        case .completed, .accepted: nil
        case .alreadySatisfied(let state): "Already \(state.rawValue)."
        case .refused(.moving), .refused(.inFlight): DoorCard.alreadyMoving
        case .refused(.coolingDown): DoorCard.justMoved
        default: dialog(doorName: name)
        }
    }
}
