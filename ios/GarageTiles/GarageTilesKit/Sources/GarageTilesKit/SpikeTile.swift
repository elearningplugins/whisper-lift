import Foundation

/** The two distinguishable widget configurations used by the Phase 0 spike. */
public enum SpikeTile: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case alpha
    case bravo

    public var title: String {
        switch self {
        case .alpha: "Tile A"
        case .bravo: "Tile B"
        }
    }

    public var symbolName: String {
        switch self {
        case .alpha: "a.square.fill"
        case .bravo: "b.square.fill"
        }
    }
}
