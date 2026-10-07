import Foundation
import PropertyTestSupport
import Testing
@testable import GarageTilesKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GarageTilesKitProps-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct CounterSnapshotProperties {
    @Test func incrementsConserveEveryTapAndRememberTheLast() {
        forAll({ rng in (Gen.tiles(&rng), Gen.writer(&rng), Gen.date(&rng)) }) { tiles, writer, date in
            let result = tiles.reduce(CounterSnapshot.empty) { $0.incremented(tile: $1, writer: writer, at: date) }
            let perTileMatches = SpikeTile.allCases.allSatisfy { tile in result.taps(for: tile) == tiles.filter { $0 == tile }.count }
            let sum = SpikeTile.allCases.map(result.taps(for:)).reduce(0, +)
            let lastMatches = tiles.isEmpty ? result == .empty : result.lastTile == tiles.last && result.lastWriter == writer && result.lastTapAt == date
            return result.total == tiles.count && sum == result.total && perTileMatches && lastMatches
        }
    }

    @Test func incrementingNeverChangesOtherTilesCounts() {
        forAll({ rng in (Gen.tiles(&rng), Bool.random(using: &rng) ? SpikeTile.alpha : .bravo) }) { history, tile in
            let before = history.reduce(CounterSnapshot.empty) { $0.incremented(tile: $1, writer: nil, at: .distantPast) }
            let after = before.incremented(tile: tile, writer: nil, at: .distantPast)
            return SpikeTile.allCases.allSatisfy { other in
                after.taps(for: other) == before.taps(for: other) + (other == tile ? 1 : 0)
            }
        }
    }
}

@Suite struct CounterStoreProperties {
    @Test func incrementReturnsExactlyWhatALaterReadSees() throws {
        let directory = try temporaryDirectory()
        try forAll(iterations: 60, { rng in (Bool.random(using: &rng) ? SpikeTile.alpha : .bravo, Gen.writer(&rng), Gen.date(&rng)) }) { tile, writer, date in
            let store = CounterStore(directory: directory)
            let returned = try store.increment(tile: tile, writer: writer, now: date)
            return try store.read() == returned
        }
    }
}

@Suite struct CounterStoreRegressions {
    // Pinned from incrementReturnsExactlyWhatALaterReadSees: ISO 8601 storage drops sub-second precision that Date() always has.
    @Test func incrementWithFractionalSecondsReturnsTheStoredSnapshot() throws {
        let store = CounterStore(directory: try temporaryDirectory())
        let returned = try store.increment(tile: .alpha, writer: "w", now: Date(timeIntervalSince1970: 1_790_000_000.75))
        #expect(try store.read() == returned)
        #expect(returned.lastTapAt == Date(timeIntervalSince1970: 1_790_000_000))
    }
}
