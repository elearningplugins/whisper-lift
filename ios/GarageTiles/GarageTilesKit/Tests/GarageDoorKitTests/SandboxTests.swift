import Foundation
import Testing
@testable import GarageDoorKit

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private struct LiveFactoryReached: Error {}

@Suite struct SandboxSelectionTests {
    @Test func aSandboxedRunNeverReachesTheLiveFactory() throws {
        let calls = Calls()
        let env = try GarageEnvironment.select(sandboxed: true) {
            calls.bump()
            throw LiveFactoryReached()
        }
        #expect(calls.count == 0, "the live factory reads the real App Group and Keychain, so a sandboxed run must never call it")
        #expect(env.tokenStore.accessGroup == GarageEnvironment.sandboxKeychainGroup)
    }

    @Test func aNormalRunUsesTheLiveFactory() {
        let calls = Calls()
        let marker = GarageEnvironment.sandbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Live-\(UUID().uuidString)"))
        let env = GarageEnvironment.select(sandboxed: false) {
            calls.bump()
            return marker
        }
        #expect(calls.count == 1)
        #expect(env.catalogStore.directory == marker.catalogStore.directory)
    }

    @Test func everySandboxedCallerSharesOneSandbox() {
        #expect(GarageEnvironment.sharedSandbox.catalogStore.directory == GarageEnvironment.sharedSandbox.catalogStore.directory)
        #expect(GarageEnvironment.sharedSandbox.tokenStore.accessGroup == GarageEnvironment.sandboxKeychainGroup)
    }

    @Test func theSandboxCannotReachMyQEvenWithASessionAndDoors() async throws {
        let env = GarageEnvironment.sandbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Sandbox-\(UUID().uuidString)"))
        #expect(try env.tokenStore.read() == nil, "it starts signed out")
        #expect(await env.refreshStatus() == .noDoors)
        let door = CatalogDoor(identity: DoorIdentity(accountID: "account-1", serial: "door-1"), accountName: "Demo Home", name: "Single Car Garage")
        try env.catalogStore.write(DoorCatalog(doors: [door]))
        try env.tokenStore.write(TokenRecord(accessToken: "a", refreshToken: "r", accessTokenExpiry: .distantFuture, generation: 1, lastRefresh: nil))
        #expect(await env.refreshStatus() == .unreachable)
        let result = await env.perform(.open, on: door.identity)
        #expect(result.outcome == .refused(.liveStateUnavailable))
        let log = try env.trafficLog.read()
        #expect(!log.isEmpty)
        #expect(log.allSatisfy { $0.status == nil }, "every request fails before leaving the device")
        #expect(!log.contains { $0.method == "PUT" }, "no command is ever attempted")
    }

    @Test func eachSandboxHasItsOwnInMemoryKeychain() throws {
        let first = GarageEnvironment.sandbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SandboxA-\(UUID().uuidString)"))
        let second = GarageEnvironment.sandbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SandboxB-\(UUID().uuidString)"))
        try first.tokenStore.write(TokenRecord(accessToken: "a", refreshToken: "r", accessTokenExpiry: .distantFuture, generation: 1, lastRefresh: nil))
        #expect(try second.tokenStore.read() == nil, "nothing is written to a shared or real Keychain")
    }
}

// A review found the sandbox only on the doors screen while Siri's door lookup and intents still built the live environment; this keeps every caller on one switch.
@Suite struct LiveEnvironmentBoundaryTests {
    @Test func onlyAppEnvironmentBuildsAnEnvironment() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var scanned = 0
        for folder in ["GarageTiles", "Shared"] {
            let files = try #require(FileManager.default.enumerator(at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            for file in files where file.pathExtension == "swift" {
                scanned += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                if file.lastPathComponent != "AppEnvironment.swift", source.contains("GarageEnvironment.live(") || source.contains("GarageEnvironment(") || source.contains(".sandbox(") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(scanned >= 5, "the app sources were found")
        #expect(offenders.isEmpty, "build environments only through AppEnvironment.current: \(offenders)")
    }
}
