import Testing
@testable import GarageTilesKit

@Suite struct AppGroupTests {
    @Test(arguments: ["group.com.example.garagetiles", "group.x"])
    func acceptsExpandedGroupIdentifiers(_ raw: String) {
        #expect(AppGroup.validatedIdentifier(raw) == raw)
    }

    @Test(arguments: ["", "group.", "com.example.garagetiles", "group.$(BUNDLE_ID_PREFIX).garagetiles", " group.com.example", "group.com.example\n"])
    func rejectsMissingOrUnexpandedIdentifiers(_ raw: String) {
        #expect(AppGroup.validatedIdentifier(raw) == nil)
    }

    @Test func rejectsNonStringValues() {
        #expect(AppGroup.validatedIdentifier(nil) == nil)
        #expect(AppGroup.validatedIdentifier(42) == nil)
    }
}

@Suite struct SpikeTileTests {
    @Test func tilesAreDistinguishable() {
        #expect(Set(SpikeTile.allCases.map(\.title)).count == SpikeTile.allCases.count)
        #expect(Set(SpikeTile.allCases.map(\.symbolName)).count == SpikeTile.allCases.count)
        #expect(SpikeTile.allCases.count == 2)
    }
}
