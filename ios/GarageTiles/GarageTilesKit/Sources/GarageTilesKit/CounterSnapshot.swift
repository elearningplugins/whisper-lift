import Foundation

/** The non-secret counter state shared between the app, the widget extension and intents through the App Group. */
public struct CounterSnapshot: Codable, Equatable, Sendable {
    public var total: Int
    public var tapsByTile: [SpikeTile: Int]
    public var lastTile: SpikeTile?
    public var lastTapAt: Date?
    // Bundle identifier of the process that performed the last increment, which shows whether a tap ran in the widget extension or the app.
    public var lastWriter: String?

    public static let empty = CounterSnapshot(total: 0, tapsByTile: [:], lastTile: nil, lastTapAt: nil, lastWriter: nil)

    public init(total: Int, tapsByTile: [SpikeTile: Int], lastTile: SpikeTile?, lastTapAt: Date?, lastWriter: String?) {
        self.total = total
        self.tapsByTile = tapsByTile
        self.lastTile = lastTile
        self.lastTapAt = lastTapAt
        self.lastWriter = lastWriter
    }

    public func taps(for tile: SpikeTile) -> Int {
        tapsByTile[tile, default: 0]
    }

    /** Labels the last writer as this app or another process; a nil current bundle never counts as the app. */
    public func writerDescription(currentBundle: String?) -> String {
        guard let lastWriter else { return "\u{2013}" }
        if let currentBundle, lastWriter == currentBundle { return "App (\(lastWriter))" }
        return "Other process (\(lastWriter))"
    }

    func incremented(tile: SpikeTile, writer: String?, at date: Date) -> CounterSnapshot {
        var next = self
        next.total += 1
        next.tapsByTile[tile, default: 0] += 1
        next.lastTile = tile
        next.lastTapAt = date
        next.lastWriter = writer
        return next
    }
}
