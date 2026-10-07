import Foundation
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Env-\(UUID().uuidString)", isDirectory: true)
}

private func environment(_ directory: URL, keychain: FakeKeychain, transport: FakeTransport) -> GarageEnvironment {
    GarageEnvironment(
        dataDirectory: directory, keychainGroup: "ABCDE12345.com.example.GarageTiles", transport: transport, keychain: keychain,
        profile: .siri, now: { now }, sleep: { _ in }
    )
}

private let big = CatalogDoor(identity: DoorIdentity(accountID: "account-1", serial: "door-2"), accountName: "Demo Home", name: "Two Car Garage")

private func devicesJSON(_ state: String) -> Result<HTTPResponse, MyQError> {
    .success(HTTPResponse(status: 200, headers: [:], body: Data("""
    {"items":[{"serial_number":"door-2","name":"Two Car Garage","device_family":"garagedoor","state":{"door_state":"\(state)","online":true,"is_unattended_open_allowed":true,"is_unattended_close_allowed":true}}]}
    """.utf8)))
}

private func signedIn(_ keychain: FakeKeychain) throws {
    let record = TokenRecord(accessToken: "access", refreshToken: "refresh", accessTokenExpiry: .distantFuture, generation: 1, lastRefresh: nil)
    keychain.stored = try JSONEncoder().encode(record)
}

@Suite struct GarageEnvironmentTests {
    @Test func unknownDoorIsRefusedWithoutAnyRequest() async {
        let transport = FakeTransport([])
        let env = environment(tempDirectory(), keychain: FakeKeychain(), transport: transport)
        let result = await env.perform(.open, on: big.identity)
        #expect(result.outcome == .refused(.missing))
        #expect(result.dialog == "I couldn't find that garage door. Open Whisper Lift to set it up again.")
        #expect(transport.requests.isEmpty)
    }

    @Test func noSessionAsksToSignIn() async throws {
        let directory = tempDirectory()
        let env = environment(directory, keychain: FakeKeychain(), transport: FakeTransport([]))
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        let result = await env.perform(.open, on: big.identity)
        #expect(result.outcome == .signInRequired)
        #expect(result.dialog == "Open Whisper Lift and sign in again.")
    }

    @Test func openSendsOneCommandAndSpeaksTheDoorName() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let transport = FakeTransport([devicesJSON("closed"), .success(HTTPResponse(status: 202, headers: [:], body: Data()))])
        let env = environment(tempDirectory(), keychain: keychain, transport: transport)
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        let result = await env.perform(.open, on: big.identity)
        #expect(result.outcome == .accepted(lastObserved: .opening))
        #expect(result.dialog == "Two Car Garage is opening.")
        #expect(transport.requests.map(\.method) == ["GET", "PUT"])
        #expect(transport.requests[1].url.path.hasSuffix("/door_openers/door-2/open"))
    }

    @Test func alreadyOpenDoorSendsNothing() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let transport = FakeTransport([devicesJSON("open")])
        let env = environment(tempDirectory(), keychain: keychain, transport: transport)
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        #expect(await env.perform(.open, on: big.identity).dialog == "Two Car Garage is already open.")
        #expect(transport.requests.map(\.method) == ["GET"])
    }

    @Test func storesLiveUnderTheDataDirectory() throws {
        let directory = tempDirectory()
        let env = environment(directory, keychain: FakeKeychain(), transport: FakeTransport([]))
        #expect(env.catalogStore.directory == directory)
        #expect(env.snapshotStore.directory == directory)
        #expect(env.refreshLockURL == directory.appendingPathComponent("refresh.lock"))
        #expect(env.tokenStore.accessGroup == "ABCDE12345.com.example.GarageTiles")
    }

    @Test(arguments: [
        ("ABCDE12345.com.example.GarageTiles", true), ("$(AppIdentifierPrefix)com.example.GarageTiles", false),
        ("", false), ("nodot", false), (" ABCDE12345.com.example", false),
    ])
    func keychainGroupValidation(_ raw: String, _ valid: Bool) {
        #expect((GarageEnvironment.validatedKeychainGroup(raw) != nil) == valid)
    }
}

@Suite struct GarageEnvironmentSignInTests {
    @Test func signInSavesTheSessionToTheKeychainAndMetersTheTraffic() async throws {
        let keychain = FakeKeychain()
        let transport = FakeTransport([
            .success(HTTPResponse(status: 200, headers: [:], body: Data(#"{"token":"app-check-1"}"#.utf8))),
            .success(HTTPResponse(status: 200, headers: [:], body: Data(#"{"access_token":"secret-access","refresh_token":"secret-refresh","expires_in":1800}"#.utf8))),
        ])
        let env = GarageEnvironment(
            dataDirectory: tempDirectory(), keychainGroup: "ABCDE12345.com.example.GarageTiles", transport: transport, keychain: keychain,
            configuration: try MyQConfiguration(info: [MyQConfiguration.appCheckDebugTokenInfoKey: fakeDebugToken]), now: { now }
        )
        let authenticator = FakeAuthenticator(result: .success(URL(string: "com.myqops://android?code=C&state=S1")!), seen: SeenURLs())
        try await env.signIn(with: authenticator, makeState: { "S1" })

        let saved = try #require(try env.tokenStore.read())
        #expect(saved.refreshToken == "secret-refresh")
        #expect(saved.generation == 1)
        let log = try env.trafficLog.read()
        #expect(log.count == 2)
        #expect(!String(describing: log).contains("secret"))
    }

    @Test func signInWithoutConfigurationExplainsTheSetupStep() async {
        let env = environment(tempDirectory(), keychain: FakeKeychain(), transport: FakeTransport([]))
        await #expect(throws: SignInError.notConfigured) {
            try await env.signIn(with: FakeAuthenticator(result: .failure(.cancelled), seen: SeenURLs()))
        }
        #expect(SignInError.notConfigured.description.contains("MyQ.local.xcconfig"))
    }
}

@Suite struct GarageEnvironmentSignOutTests {
    @Test func signOutDeletesTheSharedKeychainItem() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([]))
        try await env.signOut()
        #expect(keychain.stored == nil)
        #expect(try env.tokenStore.read() == nil)
    }

    @Test func aKeychainFailureIsReportedNotHidden() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        keychain.deleteStatus = errSecInteractionNotAllowed
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([]))
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        await #expect(throws: GarageEnvironment.SignOutError.sessionNotRemoved) { try await env.signOut() }
        #expect(keychain.stored != nil)
        #expect(try env.catalogStore.read().doors == [big], "nothing else is deleted while the session still exists")
    }

    @Test func signOutLeavesNoLocalDataBehind() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let directory = tempDirectory()
        let env = environment(directory, keychain: keychain, transport: FakeTransport([]))
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        try env.snapshotStore.upsert(DoorSnapshot(
            device: DoorDevice(identity: big.identity, accountName: big.accountName, name: big.name, family: "garagedoor", state: .closed, online: true,
                unattendedOpenAllowed: true, unattendedCloseAllowed: true, vacationMode: nil, activeFaults: [], lastServerUpdate: nil
            ),
            fetchedAt: now, lastCommand: nil, lastCommandAt: nil, problem: nil
        ))
        try env.trafficLog.append(TrafficEntry(date: now, method: "GET", host: "devices.myq-cloud.com", path: "/api/v6.2/Accounts/account-1/Devices", status: 200, requestBytes: 10, responseBytes: 20))
        try await env.signOut()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(remaining.allSatisfy { $0.hasSuffix(".lock") }, "only lock files may remain, found \(remaining)")
        #expect(try env.catalogStore.read().doors.isEmpty)
        #expect(try env.snapshotStore.read().isEmpty)
        #expect(try env.trafficLog.read().isEmpty)
        #expect(try env.tokenStore.read() == nil)
    }

    @Test func signOutWithNothingStoredSucceeds() async throws {
        let env = environment(tempDirectory(), keychain: FakeKeychain(), transport: FakeTransport([]))
        try await env.signOut()
    }

    @Test func aRunningDoorCommandKeepsItsDataAndIsReported() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([]))
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        let lockURL = FileCommandLock(directory: env.catalogStore.directory).url(for: big.identity)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        // A second descriptor on the same file conflicts with this flock even within one process.
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: GarageEnvironment.SignOutError.commandInProgress) { try await env.signOut() }
        #expect(keychain.stored == nil, "the session is removed first, so no new command can start")
        #expect(try env.catalogStore.read().doors == [big])
        flock(descriptor, LOCK_UN)
        try await env.signOut()
        #expect(try env.catalogStore.read().doors.isEmpty)
    }
}
