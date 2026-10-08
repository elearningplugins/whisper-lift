import Foundation
import GarageDoorKit

/** The only place the app builds a GarageEnvironment: the doors screen, Siri's door lookup, the shortcut refresh and the intents all come here, so the UI-test sandbox covers them all. */
enum AppEnvironment {
    static let sandboxArgument = "-WhisperLiftUITestSandbox"

    static func current(profile: CommandProfile = .interactive) throws -> GarageEnvironment {
        try GarageEnvironment.select(sandboxed: isSandboxed) { try GarageEnvironment.live(profile: profile) }
    }

    // UI tests pass the flag; only Debug builds honor it, so a release always uses the live environment.
    static var isSandboxed: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains(sandboxArgument)
        #else
        false
        #endif
    }
}
