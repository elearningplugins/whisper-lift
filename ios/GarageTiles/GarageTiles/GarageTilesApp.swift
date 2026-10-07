import SwiftUI

@main
struct GarageTilesApp: App {
    init() {
        // Seeds Siri's door-name cache on every launch, so phrases like "Close small door with Whisper Lift" match even after a reinstall or update.
        GarageTilesShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Doors", systemImage: "door.garage.closed") {
                    DoorsView()
                }
                Tab("Spike", systemImage: "plus.square") {
                    ContentView()
                }
            }
        }
    }
}
