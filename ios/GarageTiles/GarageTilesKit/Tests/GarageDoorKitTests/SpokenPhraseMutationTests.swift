import Foundation
import Testing
@testable import GarageDoorKit

/** Mutates how people actually say each door's name and checks the matcher: never the wrong door, and a reported hit rate. */
enum SpokenMutations {
    static let single = CatalogDoor(identity: DoorIdentity(accountID: "a", serial: "door-1"), accountName: "Home", name: "Single Car Garage")
    static let double = CatalogDoor(identity: DoorIdentity(accountID: "a", serial: "door-2"), accountName: "Home", name: "Two Car Garage")
    static let catalog = DoorCatalog(doors: [single, double])

    static let bases: [(door: CatalogDoor, phrase: String)] = [
        (single, "single car garage"), (single, "small garage"), (single, "one car garage"), (single, "single garage"), (single, "1 car garage"),
        (double, "two car garage"), (double, "big garage"), (double, "double garage"), (double, "2 car garage"),
    ]

    /** Each mutation rewrites a phrase the way speech or habit might. */
    static let mutations: [(name: String, apply: @Sendable (String) -> String)] = [
        ("as said", { $0 }),
        ("Title Case", { $0.capitalized }),
        ("leading the", { "the " + $0 }),
        ("leading my", { "my " + $0 }),
        ("leading our", { "our " + $0 }),
        ("trailing door", { $0 + " door" }),
        ("plural", { $0 + "s" }),
        ("possessive", { $0 + "'s door" }),
        ("hyphenated", { $0.replacingOccurrences(of: " car", with: "-car") }),
        ("joined car", { $0.replacingOccurrences(of: " car", with: "car") }),
        ("garage first", { $0.hasSuffix(" garage") ? "garage " + $0.dropLast(7) : $0 }),
        ("one to 1", { $0.replacingOccurrences(of: "one ", with: "1 ") }),
        ("two to 2", { $0.replacingOccurrences(of: "two ", with: "2 ") }),
        ("heard to", { $0.replacingOccurrences(of: "two ", with: "to ") }),
        ("heard too", { $0.replacingOccurrences(of: "two ", with: "too ") }),
        ("heard won", { $0.replacingOccurrences(of: "one ", with: "won ") }),
        ("heard singles", { $0.replacingOccurrences(of: "single ", with: "singles ") }),
        ("dropped garage", { $0.replacingOccurrences(of: " garage", with: "") }),
        ("trailing period", { $0 + "." }),
        ("extra spaces", { "  " + $0.replacingOccurrences(of: " ", with: "   ") + " " }),
        ("garage door", { $0.replacingOccurrences(of: "garage", with: "garage door") }),
        ("the one car", { $0.replacingOccurrences(of: "single car", with: "one car") }),
        ("little", { $0.replacingOccurrences(of: "small", with: "little") }),
        ("large", { $0.replacingOccurrences(of: "big", with: "large") }),
        ("double car", { $0.replacingOccurrences(of: "two car", with: "double car") }),
    ]

    enum Result: String { case right, noMatch = "no match", wrong = "WRONG DOOR", ambiguous }

    static func run() -> [(base: String, mutation: String, spoken: String, result: Result)] {
        var rows: [(String, String, String, Result)] = []
        var seen = Set<String>()
        for (door, phrase) in bases {
            for (name, apply) in mutations {
                let spoken = apply(phrase)
                guard seen.insert(spoken).inserted else { continue }
                let result: Result = switch catalog.resolve(spoken) {
                case .door(let found): found == door ? .right : .wrong
                case .ambiguous: .ambiguous
                case .noMatch: .noMatch
                }
                rows.append((phrase, name, spoken, result))
            }
        }
        return rows
    }
}

@Suite struct SpokenPhraseMutationTests {
    @Test func noVariationEverResolvesToTheOtherDoor() {
        let rows = SpokenMutations.run()
        let wrong = rows.filter { $0.result == .wrong || $0.result == .ambiguous }
        #expect(wrong.isEmpty, "\(wrong.map(\.spoken))")
    }

    @Test func report() throws {
        let rows = SpokenMutations.run()
        var lines = ["result\tmutation\tspoken"]
        lines += rows.map { "\($0.result.rawValue)\t\($0.mutation)\t\($0.spoken)" }
        let summary = Dictionary(grouping: rows, by: \.result).mapValues(\.count)
        lines.append("SUMMARY right=\(summary[.right] ?? 0) noMatch=\(summary[.noMatch] ?? 0) wrong=\(summary[.wrong] ?? 0) ambiguous=\(summary[.ambiguous] ?? 0) total=\(rows.count)")
        if let path = ProcessInfo.processInfo.environment["SPOKEN_REPORT"] {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

@Suite struct SpokenPhraseCoverageTests {
    @Test(arguments: [
        "my small garage", "our single car garage", "small garage door", "the small garage door", "small garages", "single car garage's door",
        "single car", "small", "single", "garage single car", "1car garage", "onecar garage", "single-car garage", "won car garage", "singles car garage",
        "little garage", "the little garage", "one car", "1 car", "small door", "the small door", "my small door",
    ])
    func everydayWaysToNameTheSingleCarDoor(_ spoken: String) {
        #expect(SpokenMutations.catalog.resolve(spoken) == .door(SpokenMutations.single))
    }

    @Test(arguments: [
        "my big garage", "our two car garage", "big garage door", "big garages", "two car garage's door", "two car", "big", "double",
        "garage two car", "2car garage", "twocar garage", "two-car garage", "to car garage", "too car garage", "large garage", "double car garage", "2 car",
        "big door", "the big door", "our big door",
    ])
    func everydayWaysToNameTheTwoCarDoor(_ spoken: String) {
        #expect(SpokenMutations.catalog.resolve(spoken) == .door(SpokenMutations.double))
    }

    @Test(arguments: ["garage", "garage door", "door", "my garage", "the", "car", "three car garage", "front door", "to", "won"])
    func vagueOrUnknownNamesStillMatchNothing(_ spoken: String) {
        #expect(SpokenMutations.catalog.resolve(spoken) == .noMatch)
    }

    @Test func mostMutationsNowResolve() {
        let rows = SpokenMutations.run()
        let right = rows.filter { $0.result == .right }.count
        #expect(Double(right) / Double(rows.count) >= 0.9, "\(right) of \(rows.count)")
    }

    @Test func extraDoorsInTheCatalogNeverCauseAWrongMatch() {
        let others = ["Driveway Gate", "Front Door", "Shed", "Garage", "Big Barn", "Carport", "Side Door", "Two Car Carport"]
        for count in 0...others.count {
            let extras = others.prefix(count).enumerated().map { CatalogDoor(identity: DoorIdentity(accountID: "a", serial: "x\($0.offset)"), accountName: "Home", name: $0.element) }
            let catalog = DoorCatalog(doors: [SpokenMutations.single, SpokenMutations.double] + extras)
            for (door, phrase) in SpokenMutations.bases {
                for (_, apply) in SpokenMutations.mutations {
                    if case .door(let found) = catalog.resolve(apply(phrase)) {
                        let otherMain = door == SpokenMutations.single ? SpokenMutations.double : SpokenMutations.single
                        #expect(found != otherMain, "\(apply(phrase)) opened \(found.name) with \(count) extra doors")
                    }
                }
            }
        }
    }
}

@Suite struct StackedSpokenMutationTests {
    // Every pair of mutations applied in sequence: still never the wrong door, and the match rate is reported.
    @Test func pairedMutationsNeverReachTheOtherDoor() throws {
        var right = 0, noMatch = 0, wrong: [String] = []
        var seen = Set<String>()
        for (door, phrase) in SpokenMutations.bases {
            for (_, first) in SpokenMutations.mutations {
                for (_, second) in SpokenMutations.mutations {
                    let spoken = second(first(phrase))
                    guard seen.insert(spoken).inserted else { continue }
                    switch SpokenMutations.catalog.resolve(spoken) {
                    case .door(let found) where found == door: right += 1
                    case .noMatch: noMatch += 1
                    default: wrong.append(spoken)
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong)")
        if let path = ProcessInfo.processInfo.environment["SPOKEN_PAIRS_REPORT"] {
            try "right=\(right) noMatch=\(noMatch) wrong=\(wrong.count) total=\(seen.count)".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
