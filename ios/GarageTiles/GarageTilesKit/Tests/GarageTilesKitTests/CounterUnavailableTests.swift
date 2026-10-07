import Foundation
import PropertyTestSupport
import Testing
@testable import GarageTilesKit

@Suite struct CounterUnavailableTests {
    @Test(arguments: [
        (AppGroup.ResolutionError.missingIdentifier as any Error, CounterUnavailable.appGroupMissing),
        (AppGroup.ResolutionError.containerUnavailable(identifier: "group.x"), .appGroupMissing),
        (CounterStore.StoreError.unreadable, .protectedData),
        (CounterStore.StoreError.lockUnavailable(errno: EPERM), .protectedData),
        (CounterStore.StoreError.lockUnavailable(errno: EACCES), .protectedData),
        (CounterStore.StoreError.lockUnavailable(errno: ENOSPC), .unexpected),
        (CounterStore.StoreError.lockTimedOut, .busy),
        (CounterStore.StoreError.malformedData, .damaged),
        (CounterStore.StoreError.writeFailed, .unexpected),
        (CounterStore.StoreError.directoryUnavailable, .unexpected),
        (CocoaError(.fileReadNoPermission), .unexpected),
    ])
    func classifiesEachError(_ error: any Error, _ expected: CounterUnavailable) {
        #expect(CounterUnavailable(error) == expected)
    }

    @Test func onlyLockScreenProtectionAsksTheDriverToUnlock() {
        #expect(CounterUnavailable.protectedData.headline == "Unlock iPhone")
        #expect(CounterUnavailable.appGroupMissing.headline == "App Group missing")
        #expect(CounterUnavailable.busy.headline == "Busy, tap again")
        #expect(CounterUnavailable.damaged.headline == "Counter damaged")
        #expect(CounterUnavailable.unexpected.headline == "Counter unavailable")
    }

    @Test func guidanceNamesTheFixForEachReason() {
        #expect(CounterUnavailable.protectedData.guidance == "Unlock the iPhone once after restarting, then try again.")
        #expect(CounterUnavailable.appGroupMissing.guidance == "Both targets need the same App Group. Check Signing & Capabilities.")
        #expect(CounterUnavailable.busy.guidance == "Another tap was still saving. Try again.")
        #expect(CounterUnavailable.damaged.guidance == "The counter file is unreadable. Delete and reinstall the app to reset it.")
        #expect(CounterUnavailable.unexpected.guidance == "Open Whisper Lift for details.")
    }

    @Test func everyReasonHasDistinctText() {
        #expect(Set(CounterUnavailable.allCases.map(\.headline)).count == CounterUnavailable.allCases.count)
        #expect(Set(CounterUnavailable.allCases.map(\.guidance)).count == CounterUnavailable.allCases.count)
    }
}

@Suite struct WriterDescriptionTests {
    private func snapshot(writer: String?) -> CounterSnapshot {
        CounterSnapshot(total: 1, tapsByTile: [.alpha: 1], lastTile: .alpha, lastTapAt: nil, lastWriter: writer)
    }

    @Test func noWriterYet() {
        #expect(snapshot(writer: nil).writerDescription(currentBundle: "com.example.app") == "–")
    }

    @Test func writtenByThisProcess() {
        #expect(snapshot(writer: "com.example.app").writerDescription(currentBundle: "com.example.app") == "App (com.example.app)")
    }

    @Test func writtenByAnotherProcess() {
        #expect(snapshot(writer: "com.example.app.Widget").writerDescription(currentBundle: "com.example.app") == "Other process (com.example.app.Widget)")
    }

    @Test func unknownCurrentBundleIsNeverTreatedAsTheApp() {
        #expect(snapshot(writer: "com.example.app").writerDescription(currentBundle: nil) == "Other process (com.example.app)")
    }
}

@Suite struct AppGroupProperties {
    private static let pieces = ["group.", "group", ".", "com", "example", "$(", ")", "BUNDLE_ID_PREFIX", " ", "\n", "\t", "-", "x"]

    @Test func acceptedIdentifiersAreUnchangedExpandedAndPrefixed() {
        forAll(iterations: 500, { rng in Gen.string(&rng, from: Self.pieces) }) { raw in
            guard let accepted = AppGroup.validatedIdentifier(raw) else { return true }
            return accepted == raw && accepted.hasPrefix("group.") && accepted.count > 6 && !accepted.contains("$(")
                && accepted.first?.isWhitespace == false && accepted.last?.isWhitespace == false
        }
    }

    @Test func anyNonEmptySuffixWithoutPlaceholdersOrEdgeWhitespaceIsAccepted() {
        forAll(iterations: 500, { rng in Gen.string(&rng, from: ["com", "example", ".", "-", "x", "Garage_Tiles"]) }) { suffix in
            let raw = "group." + suffix
            return AppGroup.validatedIdentifier(raw) == (suffix.isEmpty ? nil : raw)
        }
    }
}
