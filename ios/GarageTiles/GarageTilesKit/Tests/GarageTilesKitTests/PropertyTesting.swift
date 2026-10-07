import Foundation
import PropertyTestSupport
@testable import GarageTilesKit

enum Gen {
    static func tiles(_ rng: inout SplitMix64, maxCount: Int = 40) -> [SpikeTile] {
        (0..<Int.random(in: 0...maxCount, using: &rng)).map { _ in Bool.random(using: &rng) ? .alpha : .bravo }
    }

    /** Dates between 2001 and 2100 with arbitrary fractional seconds, as Date() produces on a device. */
    static func date(_ rng: inout SplitMix64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double.random(in: 0..<3_155_760_000, using: &rng))
    }

    static func writer(_ rng: inout SplitMix64) -> String? {
        let choices: [String?] = [nil, "", "com.example.GarageTiles", "com.example.GarageTiles.Widget", "wörker \"quoted\"\n"]
        return choices[Int.random(in: 0..<choices.count, using: &rng)]
    }

    static func string(_ rng: inout SplitMix64, from pieces: [String], maxPieces: Int = 6) -> String {
        (0..<Int.random(in: 0...maxPieces, using: &rng)).map { _ in pieces[Int.random(in: 0..<pieces.count, using: &rng)] }.joined()
    }
}
