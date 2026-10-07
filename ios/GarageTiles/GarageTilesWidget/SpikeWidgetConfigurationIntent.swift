import AppIntents
import WidgetKit

/** Selects which spike tile a widget instance represents; deliberately separate from the action intent. */
struct SpikeWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Spike Tile" }
    static var description: IntentDescription { IntentDescription("Choose which test tile this widget bumps.") }

    @Parameter(title: "Tile", default: .alpha)
    var tile: SpikeTileAppEnum

    init() {}

    init(tile: SpikeTileAppEnum) {
        self.tile = tile
    }
}
