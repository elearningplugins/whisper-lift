import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

func makeDoor(
    _ state: DoorState = .closed,
    family: String = "garagedoor",
    online: Bool? = true,
    openAllowed: Bool? = true,
    closeAllowed: Bool? = true,
    vacation: Bool? = false,
    faults: [String] = []
) -> DoorDevice {
    DoorDevice(
        identity: DoorIdentity(accountID: "account-1", serial: "door-1"), accountName: "Home", name: "Big", family: family, state: state,
        online: online, unattendedOpenAllowed: openAllowed, unattendedCloseAllowed: closeAllowed, vacationMode: vacation,
        activeFaults: faults, lastServerUpdate: nil
    )
}

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let policy = SafetyPolicy(cooldown: 10)

private func decide(_ request: DoorRequest, _ door: DoorDevice, inFlight: Bool = false, lastCommandAt: Date? = nil) -> CommandDecision {
    policy.decide(request, lookup: .found(door), inFlight: inFlight, lastCommandAt: lastCommandAt, now: now)
}

@Suite struct SafetyPolicyExamples {
    @Test func opensOnlyFromConfirmedClosed() {
        #expect(decide(.open, makeDoor(.closed)) == .send(.open))
        #expect(decide(.open, makeDoor(.open)) == .alreadySatisfied(.open))
        #expect(decide(.open, makeDoor(.opening)) == .refuse(.moving(.opening)))
        #expect(decide(.open, makeDoor(.closing)) == .refuse(.moving(.closing)))
        #expect(decide(.open, makeDoor(.stopped)) == .refuse(.stopped))
        #expect(decide(.open, makeDoor(.unknown)) == .refuse(.unknownState))
    }

    @Test func closesOnlyFromConfirmedOpen() {
        #expect(decide(.close, makeDoor(.open)) == .send(.close))
        #expect(decide(.close, makeDoor(.closed)) == .alreadySatisfied(.closed))
        #expect(decide(.close, makeDoor(.closing)) == .refuse(.moving(.closing)))
        #expect(decide(.close, makeDoor(.stopped)) == .refuse(.stopped))
        #expect(decide(.close, makeDoor(.unknown)) == .refuse(.unknownState))
    }

    @Test func togglesOnlyFromATerminalState() {
        #expect(decide(.toggle, makeDoor(.closed)) == .send(.open))
        #expect(decide(.toggle, makeDoor(.open)) == .send(.close))
        #expect(decide(.toggle, makeDoor(.opening)) == .refuse(.moving(.opening)))
        #expect(decide(.toggle, makeDoor(.stopped)) == .refuse(.stopped))
        #expect(decide(.toggle, makeDoor(.unknown)) == .refuse(.unknownState))
    }

    @Test func lookupFailuresRefuse() {
        #expect(policy.decide(.open, lookup: .missing, inFlight: false, lastCommandAt: nil, now: now) == .refuse(.missing))
        #expect(policy.decide(.open, lookup: .duplicated, inFlight: false, lastCommandAt: nil, now: now) == .refuse(.duplicated))
        #expect(policy.decide(.close, lookup: .fetchFailed, inFlight: false, lastCommandAt: nil, now: now) == .refuse(.liveStateUnavailable))
    }

    @Test func deviceGuardsRefuse() {
        #expect(decide(.open, makeDoor(family: "gateway")) == .refuse(.notGarageDoor))
        #expect(decide(.open, makeDoor(online: false)) == .refuse(.offline))
        #expect(decide(.open, makeDoor(online: nil)) == .refuse(.offline))
        #expect(decide(.open, makeDoor(faults: ["E1"])) == .refuse(.fault))
        #expect(decide(.open, makeDoor(openAllowed: false)) == .refuse(.unattendedNotAllowed(.open)))
        #expect(decide(.open, makeDoor(openAllowed: nil)) == .refuse(.unattendedNotAllowed(.open)))
        #expect(decide(.close, makeDoor(.open, closeAllowed: nil)) == .refuse(.unattendedNotAllowed(.close)))
    }

    @Test func vacationModeBlocksOpeningButNotClosing() {
        #expect(decide(.open, makeDoor(.closed, vacation: true)) == .refuse(.vacationMode))
        #expect(decide(.close, makeDoor(.open, vacation: true)) == .send(.close))
    }

    @Test func inFlightAndCooldownRefuse() {
        #expect(decide(.toggle, makeDoor(.closed), inFlight: true) == .refuse(.inFlight))
        #expect(decide(.toggle, makeDoor(.closed), lastCommandAt: now.addingTimeInterval(-9.999)) == .refuse(.coolingDown(until: now.addingTimeInterval(0.001))))
        #expect(decide(.toggle, makeDoor(.closed), lastCommandAt: now.addingTimeInterval(-10)) == .send(.open))
        #expect(decide(.toggle, makeDoor(.closed), lastCommandAt: now.addingTimeInterval(5)) == .refuse(.coolingDown(until: now.addingTimeInterval(15))))
    }

    @Test func alreadySatisfiedWinsOverCooldownAndInFlight() {
        #expect(decide(.open, makeDoor(.open), inFlight: true, lastCommandAt: now) == .alreadySatisfied(.open))
    }

    @Test func offlineIsCheckedBeforeAlreadySatisfied() {
        #expect(decide(.open, makeDoor(.open, online: false)) == .refuse(.offline))
    }
}

@Suite struct SafetyPolicyProperties {
    private struct Case: CustomStringConvertible {
        let request: DoorRequest
        let door: DoorDevice
        let inFlight: Bool
        let lastCommandOffset: TimeInterval?
        var description: String { "\(request) \(door.state) online=\(String(describing: door.online)) family=\(door.family) inFlight=\(inFlight) last=\(String(describing: lastCommandOffset))" }
    }

    private func generate(_ rng: inout SplitMix64) -> Case {
        func optionalBool(_ rng: inout SplitMix64) -> Bool? { [true, false, nil][Int.random(in: 0..<3, using: &rng)] }
        let door = makeDoor(
            DoorState.allCases.randomElement(using: &rng)!,
            family: ["garagedoor", "gateway", "lamp"].randomElement(using: &rng)!,
            online: optionalBool(&rng),
            openAllowed: optionalBool(&rng),
            closeAllowed: optionalBool(&rng),
            vacation: optionalBool(&rng),
            faults: Bool.random(using: &rng) ? [] : ["E1"]
        )
        let offset: TimeInterval? = Bool.random(using: &rng) ? nil : Double.random(in: -30...30, using: &rng)
        return Case(request: [.open, .close, .toggle].randomElement(using: &rng)!, door: door, inFlight: Bool.random(using: &rng), lastCommandOffset: offset)
    }

    private func decision(_ c: Case) -> CommandDecision {
        decide(c.request, c.door, inFlight: c.inFlight, lastCommandAt: c.lastCommandOffset.map { now.addingTimeInterval($0) })
    }

    @Test func everySendHasPassedEveryGuard() {
        forAll(iterations: 2000, generate) { c in
            guard case .send(let action) = decision(c) else { return true }
            let door = c.door
            let allowed = action == .open ? door.unattendedOpenAllowed : door.unattendedCloseAllowed
            let fromState: DoorState = action == .open ? .closed : .open
            let coolingDown = c.lastCommandOffset.map { $0 > -policy.cooldown } ?? false
            return door.isGarageDoor && door.online == true && door.activeFaults.isEmpty && allowed == true && door.state == fromState
                && !c.inFlight && !coolingDown && !(action == .open && door.vacationMode == true)
        }
    }

    @Test func explicitRequestsAreNeverInverted() {
        forAll(iterations: 2000, generate) { c in
            switch (c.request, decision(c)) {
            case (.open, .send(.close)), (.close, .send(.open)): false
            case (.open, .alreadySatisfied(let state)): state == .open
            case (.close, .alreadySatisfied(let state)): state == .closed
            case (.toggle, .alreadySatisfied): false
            default: true
            }
        }
    }

    @Test func toggleAlwaysMovesAwayFromTheCurrentState() {
        forAll(iterations: 2000, generate) { c in
            guard c.request == .toggle, case .send(let action) = decision(c) else { return true }
            return (action == .open && c.door.state == .closed) || (action == .close && c.door.state == .open)
        }
    }
}
