import Foundation
import Testing
@testable import GarageDoorKit

/** A fabricated value in the debug-token shape; the real one lives only in ignored local configuration. */
let fakeDebugToken = "00000000-1111-4222-8333-444444444444"

@Suite struct MyQConfigurationTests {
    @Test func readsAndTrimsTheDebugTokenFromInfo() throws {
        let configuration = try MyQConfiguration(info: [MyQConfiguration.appCheckDebugTokenInfoKey: " \(fakeDebugToken)\n"])
        #expect(configuration.appCheckDebugToken == fakeDebugToken)
    }

    @Test(arguments: [nil, "", "   ", "$(MYQ_APP_CHECK_DEBUG_TOKEN)"] as [String?])
    func missingOrUnexpandedValuesAreNotConfigured(_ value: String?) {
        let info: [String: Any] = value.map { [MyQConfiguration.appCheckDebugTokenInfoKey: $0] } ?? [:]
        #expect(throws: MyQConfiguration.SetupError.missingAppCheckDebugToken) { try MyQConfiguration(info: info) }
    }

    @Test(arguments: ["not-a-token", fakeDebugToken + "0", "g0000000-1111-4222-8333-444444444444", "00000000111142228333444444444444"])
    func malformedValuesAreRefusedWithoutEchoingThem(_ value: String) {
        #expect(throws: MyQConfiguration.SetupError.malformedAppCheckDebugToken) {
            try MyQConfiguration(info: [MyQConfiguration.appCheckDebugTokenInfoKey: value])
        }
        #expect(!MyQConfiguration.SetupError.malformedAppCheckDebugToken.description.contains(value))
    }

    @Test func nonStringValuesAreNotConfigured() {
        #expect(throws: MyQConfiguration.SetupError.missingAppCheckDebugToken) { try MyQConfiguration(info: [MyQConfiguration.appCheckDebugTokenInfoKey: 42]) }
    }

    @Test func sourceNoLongerShipsADebugToken() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let shape = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        for file in files {
            #expect(try String(contentsOf: file, encoding: .utf8).firstMatch(of: shape) == nil, "\(file.lastPathComponent) contains a UUID-shaped value")
        }
    }
}
