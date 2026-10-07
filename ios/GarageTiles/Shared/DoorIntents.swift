import AppIntents
import GarageDoorKit
import WidgetKit

/** Opens one door after a live myQ check; already open is success, and it never closes a door (PLAN.md Phase 7). */
struct OpenDoorIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Door" }
    static var description: IntentDescription { IntentDescription("Opens a garage door after checking its live state. It does nothing if the door is already open.") }
    static var openAppWhenRun: Bool { false }
    // CarPlay and Siri use is expected while the phone is locked; the app's setup screen warns about this.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Door")
    var door: DoorEntity

    init() {}

    init(door: DoorEntity) {
        self.door = door
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$door)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await DoorIntentRunner.run(.open, door: door)
    }
}

/** Closes one door after a live myQ check; already closed is success, and it never opens a door. */
struct CloseDoorIntent: AppIntent {
    static var title: LocalizedStringResource { "Close Door" }
    static var description: IntentDescription { IntentDescription("Closes a garage door after checking its live state. It does nothing if the door is already closed.") }
    static var openAppWhenRun: Bool { false }
    // CarPlay and Siri use is expected while the phone is locked; the app's setup screen warns about this.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Door")
    var door: DoorEntity

    init() {}

    init(door: DoorEntity) {
        self.door = door
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Close \(\.$door)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await DoorIntentRunner.run(.close, door: door)
    }
}

enum DoorIntentRunner {
    static func run(_ request: DoorRequest, door: DoorEntity) async throws -> some IntentResult & ProvidesDialog {
        guard let identity = DoorIdentity(entityIdentifier: door.id) else { throw DoorIntentError.notSetUp }
        let environment: GarageEnvironment
        do {
            // Siri answers as soon as myQ accepts the command, after one status read; the app screen confirms the movement.
            environment = try GarageEnvironment.live(profile: .siri)
        } catch {
            throw DoorIntentError.notSetUp
        }
        let result = await environment.perform(request, on: identity)
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "\(result.dialog)")
    }
}

enum DoorIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSetUp

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp: "Whisper Lift isn't set up. Open the app and sign in with myQ."
        }
    }
}
