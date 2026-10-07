import AppIntents
import GarageTilesKit

/** App Intents representation of the two spike tiles, used for widget configuration and Siri parameters. */
enum SpikeTileAppEnum: String, AppEnum {
    case alpha
    case bravo

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Tile" }

    static var caseDisplayRepresentations: [SpikeTileAppEnum: DisplayRepresentation] {
        [
            // Literal symbol names, because the App Intents metadata processor cannot extract SpikeTile.symbolName at build time.
            .alpha: DisplayRepresentation(title: "Tile A", image: DisplayRepresentation.Image(systemName: "a.square.fill")),
            .bravo: DisplayRepresentation(title: "Tile B", image: DisplayRepresentation.Image(systemName: "b.square.fill")),
        ]
    }

    init(_ tile: SpikeTile) {
        switch tile {
        case .alpha: self = .alpha
        case .bravo: self = .bravo
        }
    }

    var tile: SpikeTile {
        switch self {
        case .alpha: .alpha
        case .bravo: .bravo
        }
    }
}
