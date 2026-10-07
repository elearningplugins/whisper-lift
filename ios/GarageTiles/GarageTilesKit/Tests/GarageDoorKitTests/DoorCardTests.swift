import Foundation
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func snapshot(
    _ state: DoorState, online: Bool? = true, fetchedSecondsAgo: TimeInterval = 120, problem: DoorProblem? = nil, lastCommandSecondsAgo: TimeInterval? = nil,
    faults: [String] = [], vacation: Bool? = nil, openAllowed: Bool? = true, closeAllowed: Bool? = true, unreadable: [String] = []
) -> DoorSnapshot {
    let device = DoorDevice(
        identity: DoorIdentity(accountID: "account-1", serial: "door-1"), accountName: "Demo Home", name: "Main Garage", family: "garagedoor", state: state, online: online,
        unattendedOpenAllowed: openAllowed, unattendedCloseAllowed: closeAllowed, vacationMode: vacation, activeFaults: faults, lastServerUpdate: nil,
        unreadableSafetyFields: unreadable
    )
    return DoorSnapshot(
        device: device, fetchedAt: now.addingTimeInterval(-fetchedSecondsAgo), lastCommand: lastCommandSecondsAgo == nil ? nil : .open,
        lastCommandAt: lastCommandSecondsAgo.map { now.addingTimeInterval(-$0) }, problem: problem
    )
}

private func card(_ snapshot: DoorSnapshot?) -> DoorCard { DoorCard(snapshot: snapshot, now: now) }

@Suite struct DoorCardTests {
    @Test func closedIsRedAndATapOpens() {
        let closed = card(snapshot(.closed))
        #expect(closed == DoorCard(title: "Closed", detail: "Updated 2 min ago", tone: .closed, icon: .closed, dashedBorder: false, tap: .send(.open), hint: "Tap to open"))
    }

    @Test func openIsGreenAndATapCloses() {
        #expect(card(snapshot(.open)) == DoorCard(title: "Open", detail: "Updated 2 min ago", tone: .open, icon: .open, dashedBorder: false, tap: .send(.close), hint: "Tap to close"))
    }

    @Test(arguments: [(DoorState.opening, "Opening…", DoorCard.Icon.opening), (.closing, "Closing…", .closing)])
    func movingIsPurpleAndATapOnlyExplains(_ state: DoorState, _ title: String, _ icon: DoorCard.Icon) {
        let moving = card(snapshot(state, fetchedSecondsAgo: 5))
        #expect(moving == DoorCard(title: title, detail: "Updated just now", tone: .moving, icon: icon, dashedBorder: false, tap: .explain("Already moving. Wait for it to finish."), hint: "Moving"))
    }

    @Test func rightAfterACommandATapExplainsTheCooldownWithoutSending() {
        let cooling = card(snapshot(.open, fetchedSecondsAgo: 3, lastCommandSecondsAgo: 4))
        #expect(cooling.title == "Open")
        #expect(cooling.tone == .open)
        #expect(cooling.detail == "Just moved. Try again in a few seconds.")
        #expect(cooling.tap == .explain("Just moved. Try again in a few seconds."))
        #expect(card(snapshot(.open, lastCommandSecondsAgo: 16)).tap == .send(.close), "the cooldown matches the safety policy's 15 seconds")
    }

    @Test(arguments: [
        (5.0, "Updated just now"), (59, "Updated just now"), (60, "Updated 1 min ago"), (3599, "Updated 59 min ago"),
        (3600, "Updated 1 hr ago"), (7200, "Updated 2 hr ago"), (86_400, "Updated 1 day ago"), (259_200, "Updated 3 days ago"),
    ])
    func updatedTextReadsNaturally(_ seconds: TimeInterval, _ expected: String) {
        #expect(card(snapshot(.closed, fetchedSecondsAgo: seconds)).detail == expected)
    }

    @Test func aFutureFetchTimeReadsAsJustNow() {
        #expect(card(snapshot(.closed, fetchedSecondsAgo: -30)).detail == "Updated just now")
    }

    @Test func neverCheckedIsANeutralDashedProblem() {
        #expect(card(nil) == DoorCard(title: "Not checked yet", detail: "The app hasn't heard from this door yet.", tone: .neutral, icon: .clock, dashedBorder: true, tap: .none, hint: nil))
    }

    @Test func problemsUseTheDesignsCardsInPriorityOrder() {
        let expectations: [(DoorSnapshot, String, DoorCard.Tone, DoorCard.Icon, Bool)] = [
            (snapshot(.closed, problem: .signInRequired), "Sign in again", .neutral, .signIn, false),
            (snapshot(.closed, problem: .uncertainCommand, faults: ["F1"]), "Not sure it worked", .warning, .question, true),
            (snapshot(.closed, online: false, faults: ["F1"]), "Can't reach door", .neutral, .offline, true),
            (snapshot(.closed, online: nil), "Can't reach door", .neutral, .offline, true),
            (snapshot(.closed, faults: ["F1"], unreadable: ["in_vacation_mode"]), "Safety status unreadable", .warning, .warning, false),
            (snapshot(.open, faults: ["F1"], vacation: true), "Door has a fault", .warning, .warning, false),
            (snapshot(.stopped), "Stopped partway", .neutral, .question, false),
            (snapshot(.unknown), "Position unknown", .neutral, .question, true),
            (snapshot(.closed, vacation: true), "Vacation mode is on", .neutral, .locked, false),
            (snapshot(.closed, openAllowed: false, closeAllowed: false), "Remote control is off", .neutral, .locked, false),
        ]
        for (input, title, tone, icon, dashed) in expectations {
            let problem = card(input)
            #expect(problem.title == title)
            #expect(problem.tone == tone, "\(title)")
            #expect(problem.icon == icon, "\(title)")
            #expect(problem.dashedBorder == dashed, "\(title)")
            #expect(problem.tap == .none, "a problem card never sends a command on tap: \(title)")
            #expect(problem.isProblem)
            #expect(!problem.detail.isEmpty)
        }
    }

    @Test func designWordingForTheCommonProblems() {
        #expect(card(snapshot(.closed, problem: .uncertainCommand)).detail == "The command was sent, but the door didn't confirm. Please check on it.")
        #expect(card(snapshot(.closed, faults: ["F1"])).detail == "The opener reported a problem. Check the door, then try again.")
        #expect(card(snapshot(.unknown)).detail == "myQ didn't say if this door is open or closed.")
        #expect(card(snapshot(.closed, openAllowed: false, closeAllowed: false)).detail == "This door doesn't allow control from an app.")
    }

    @Test func onlyOneBlockedDirectionStaysANormalCard() {
        #expect(card(snapshot(.closed, openAllowed: false, closeAllowed: true)).tone == .closed)
    }

    @Test func normalCardsAreNotProblems() {
        #expect(!card(snapshot(.closed)).isProblem)
        #expect(!card(snapshot(.opening)).isProblem)
    }
}

@Suite struct CardMessageTests {
    @Test func movementAndSuccessNeedNoExtraMessage() {
        #expect(CommandOutcome.completed(.open).cardMessage(doorName: "Main Garage") == nil)
        #expect(CommandOutcome.accepted(lastObserved: .opening).cardMessage(doorName: "Main Garage") == nil)
    }

    @Test func refusalsUseTheDesignsShortWording() {
        #expect(CommandOutcome.refused(.moving(.opening)).cardMessage(doorName: "Main Garage") == "Already moving. Wait for it to finish.")
        #expect(CommandOutcome.refused(.inFlight).cardMessage(doorName: "Main Garage") == "Already moving. Wait for it to finish.")
        #expect(CommandOutcome.refused(.coolingDown(until: now)).cardMessage(doorName: "Main Garage") == "Just moved. Try again in a few seconds.")
        #expect(CommandOutcome.alreadySatisfied(.closed).cardMessage(doorName: "Main Garage") == "Already closed.")
    }

    @Test func everythingElseKeepsTheSpokenMessage() {
        for outcome in [CommandOutcome.uncertain(observed: nil), .signInRequired, .rateLimited, .unavailable, .refused(.fault), .refused(.vacationMode), .refused(.offline)] {
            #expect(outcome.cardMessage(doorName: "Main Garage") == outcome.dialog(doorName: "Main Garage"))
        }
    }
}
