import AppIntents
import Foundation
import GarageTilesKit
import WidgetKit

/** Increments the shared spike counter for one tile without opening the app; compiled into both the app and the widget extension. */
struct IncrementCounterIntent: AppIntent {
    static var title: LocalizedStringResource { "Bump Spike Counter" }
    static var description: IntentDescription { IntentDescription("Adds one to the Phase 0 test counter for a tile. It does not control any garage door.") }
    static var openAppWhenRun: Bool { false }
    // Only the spike widget's button runs it, so it stays out of Siri and the Shortcuts library.
    static var isDiscoverable: Bool { false }
    // Phase 0 must prove the tap works while the phone is locked, so the policy is explicit rather than inherited.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Tile", default: .alpha)
    var tile: SpikeTileAppEnum

    init() {}

    init(tile: SpikeTileAppEnum) {
        self.tile = tile
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Bump \(\.$tile)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let snapshot: CounterSnapshot
        do {
            snapshot = try AppGroup.counterStore().increment(tile: tile.tile, writer: Bundle.main.bundleIdentifier)
        } catch {
            throw SpikeIntentError.storeUnavailable(CounterUnavailable(error), String(describing: error))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: SpikeWidgetKind.counter)
        return .result(value: snapshot.total, dialog: "\(tile.tile.title) bumped. The total is \(snapshot.total).")
    }
}

enum SpikeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable(CounterUnavailable, String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable(let reason, let detail): "\(reason.headline). \(reason.guidance) (\(detail))"
        }
    }
}

enum SpikeWidgetKind {
    static let counter = "SpikeCounterWidget"
}
