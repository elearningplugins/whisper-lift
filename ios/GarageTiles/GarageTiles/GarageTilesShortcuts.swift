import AppIntents

/** Siri phrases for the doors only; App Shortcuts require the app name, and phrases avoid "garage" because Siri routes "open the garage" to Apple Home. */
struct GarageTilesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenDoorIntent(),
            phrases: [
                "Open \(\.$door) with \(.applicationName)",
                "Raise \(\.$door) with \(.applicationName)",
                "Open a door with \(.applicationName)",
            ],
            shortTitle: "Open Door",
            systemImageName: "door.garage.open"
        )
        AppShortcut(
            intent: CloseDoorIntent(),
            phrases: [
                "Close \(\.$door) with \(.applicationName)",
                "Lower \(\.$door) with \(.applicationName)",
                "Close a door with \(.applicationName)",
            ],
            shortTitle: "Close Door",
            systemImageName: "door.garage.closed"
        )
    }
}
