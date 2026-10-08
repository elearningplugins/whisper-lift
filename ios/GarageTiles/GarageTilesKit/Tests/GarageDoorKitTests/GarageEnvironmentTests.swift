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

@Suite struct StatusRefreshTests {
    private let small = CatalogDoor(identity: DoorIdentity(accountID: "account-1", serial: "door-1"), accountName: "Demo Home", name: "Single Car Garage")

    private func device(_ door: CatalogDoor, _ state: DoorState) -> DoorDevice {
        DoorDevice(
            identity: door.identity, accountName: door.accountName, name: door.name, family: "garagedoor", state: state, online: true,
            unattendedOpenAllowed: true, unattendedCloseAllowed: true, vacationMode: nil, activeFaults: [], lastServerUpdate: nil
        )
    }

    private func bothDoorsJSON(small smallState: String, big bigState: String) -> Result<HTTPResponse, MyQError> {
        .success(HTTPResponse(status: 200, headers: [:], body: Data("""
        {"items":[{"serial_number":"door-1","name":"Single Car Garage","device_family":"garagedoor","state":{"door_state":"\(smallState)","online":true,"is_unattended_open_allowed":true,"is_unattended_close_allowed":true}},{"serial_number":"door-2","name":"Two Car Garage","device_family":"garagedoor","state":{"door_state":"\(bigState)","online":true,"is_unattended_open_allowed":true,"is_unattended_close_allowed":true}}]}
        """.utf8)))
    }

    // Five hours old, from the last command, as on the owner's phone when the app showed a closed door as open.
    private func staleSnapshot(_ door: CatalogDoor, _ state: DoorState, problem: DoorProblem? = nil) -> DoorSnapshot {
        DoorSnapshot(device: device(door, state), fetchedAt: now.addingTimeInterval(-18_000), lastCommand: .open, lastCommandAt: now.addingTimeInterval(-18_000), problem: problem)
    }

    @Test func refreshReplacesStaleStateWithOneLiveReadPerAccount() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let transport = FakeTransport([bothDoorsJSON(small: "closed", big: "closed")])
        let env = environment(tempDirectory(), keychain: keychain, transport: transport)
        try env.catalogStore.write(DoorCatalog(doors: [small, big]))
        try env.snapshotStore.upsert(staleSnapshot(small, .open, problem: .unreachable))
        try env.snapshotStore.upsert(staleSnapshot(big, .closed))

        #expect(await env.refreshStatus() == .updated)
        #expect(transport.requests.map(\.method) == ["GET"], "one read for the one account, and never a command")
        #expect(transport.requests[0].url.path.hasSuffix("/Devices"))
        let refreshed = try #require(try env.snapshotStore.snapshot(for: small.identity))
        #expect(refreshed.device.state == .closed)
        #expect(refreshed.fetchedAt == now)
        #expect(refreshed.problem == nil)
        #expect(refreshed.lastCommandAt == now.addingTimeInterval(-18_000), "the last command time is kept for the cooldown")
        #expect(try env.snapshotStore.snapshot(for: big.identity)?.fetchedAt == now)
    }

    @Test func aDoorWithNoSavedStateGetsOne() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([bothDoorsJSON(small: "open", big: "closed")]))
        try env.catalogStore.write(DoorCatalog(doors: [small, big]))
        #expect(await env.refreshStatus() == .updated)
        #expect(try env.snapshotStore.snapshot(for: small.identity)?.device.state == .open)
        #expect(try env.snapshotStore.snapshot(for: small.identity)?.lastCommandAt == nil)
    }

    @Test func aFailedReadKeepsTheLastStateAndMarksItUnreachable() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([]))
        try env.catalogStore.write(DoorCatalog(doors: [small]))
        try env.snapshotStore.upsert(staleSnapshot(small, .open))
        #expect(await env.refreshStatus() == .unreachable)
        let kept = try #require(try env.snapshotStore.snapshot(for: small.identity))
        #expect(kept.device.state == .open)
        #expect(kept.fetchedAt == now.addingTimeInterval(-18_000), "a failed read never refreshes the age")
        #expect(kept.problem == .unreachable)
    }

    @Test func withoutASessionNothingIsSentAndTheDoorsAskToSignIn() async throws {
        let transport = FakeTransport([])
        let env = environment(tempDirectory(), keychain: FakeKeychain(), transport: transport)
        try env.catalogStore.write(DoorCatalog(doors: [small]))
        try env.snapshotStore.upsert(staleSnapshot(small, .open))
        #expect(await env.refreshStatus() == .signInRequired)
        #expect(transport.requests.isEmpty)
        #expect(try env.snapshotStore.snapshot(for: small.identity)?.problem == .signInRequired)
    }

    @Test func rateLimitingIsReported() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([.success(HTTPResponse(status: 429, headers: [:], body: Data()))]))
        try env.catalogStore.write(DoorCatalog(doors: [small]))
        #expect(await env.refreshStatus() == .rateLimited)
    }

    @Test func noDoorsMeansNoRequest() async {
        let transport = FakeTransport([])
        let env = environment(tempDirectory(), keychain: FakeKeychain(), transport: transport)
        #expect(await env.refreshStatus() == .noDoors)
        #expect(transport.requests.isEmpty)
    }

    @Test func aDoorWithACommandInProgressIsLeftToThatCommand() async throws {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: FakeTransport([bothDoorsJSON(small: "closed", big: "closed")]))
        try env.catalogStore.write(DoorCatalog(doors: [small, big]))
        let commandRecord = DoorSnapshot(device: device(small, .closed), fetchedAt: now, lastCommand: .open, lastCommandAt: now, problem: .uncertainCommand)
        try env.snapshotStore.upsert(commandRecord)
        let lockURL = FileCommandLock(directory: env.catalogStore.directory).url(for: small.identity)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(await env.refreshStatus() == .updated)
        #expect(try env.snapshotStore.snapshot(for: small.identity) == commandRecord, "a running command's uncertain record is never overwritten")
        #expect(try env.snapshotStore.snapshot(for: big.identity)?.device.state == .closed)
    }
}

@Suite struct FollowUpTests {
    private let small = CatalogDoor(identity: DoorIdentity(accountID: "account-1", serial: "door-1"), accountName: "Demo Home", name: "Single Car Garage")

    private func smallDoorJSON(_ state: String) -> Result<HTTPResponse, MyQError> {
        .success(HTTPResponse(status: 200, headers: [:], body: Data("""
        {"items":[{"serial_number":"door-1","name":"Single Car Garage","device_family":"garagedoor","state":{"door_state":"\(state)","online":true,"is_unattended_open_allowed":true,"is_unattended_close_allowed":true}}]}
        """.utf8)))
    }

    private func signedInEnvironment(_ transport: FakeTransport) throws -> GarageEnvironment {
        let keychain = FakeKeychain()
        try signedIn(keychain)
        let env = environment(tempDirectory(), keychain: keychain, transport: transport)
        try env.catalogStore.write(DoorCatalog(doors: [small]))
        return env
    }

    // The owner's door takes 12 to 15 seconds to close; three reads 3 seconds apart left the card on "Closing..." until the app was reopened.
    @Test func checksUntilTheDoorFinishesThenStops() async throws {
        let transport = FakeTransport([smallDoorJSON("closing"), smallDoorJSON("closing"), smallDoorJSON("closed"), smallDoorJSON("closed")])
        let env = try signedInEnvironment(transport)
        let slept = SleepRecorder()
        let updates = UpdateCounter()
        await env.followUp(after: .close, on: small.identity, interval: .seconds(5), maximumChecks: 8, sleep: { await slept.record($0) }, onCheck: { await updates.bump() })
        #expect(transport.requests.map(\.method) == ["GET", "GET", "GET"], "stops at the first closed reading and never sends a command")
        #expect(await slept.durations == [.seconds(5), .seconds(5), .seconds(5)])
        #expect(await updates.count == 3, "the screen refreshes after every check")
        #expect(try env.snapshotStore.snapshot(for: small.identity)?.device.state == .closed)
    }

    @Test func givesUpAfterTheMaximumWhileStillMoving() async throws {
        let transport = FakeTransport(Array(repeating: smallDoorJSON("closing"), count: 10))
        let env = try signedInEnvironment(transport)
        await env.followUp(after: .close, on: small.identity, interval: .seconds(5), maximumChecks: 4, sleep: { _ in }, onCheck: {})
        #expect(transport.requests.count == 4)
    }

    @Test func stopsWhenTheDoorEndsSomewhereElse() async throws {
        let transport = FakeTransport([smallDoorJSON("closing"), smallDoorJSON("open"), smallDoorJSON("open")])
        let env = try signedInEnvironment(transport)
        await env.followUp(after: .close, on: small.identity, interval: .seconds(5), maximumChecks: 8, sleep: { _ in }, onCheck: {})
        #expect(transport.requests.count == 2, "a door that reversed, for example after the safety sensor saw something, is reported as it is")
        #expect(try env.snapshotStore.snapshot(for: small.identity)?.device.state == .open)
    }

    @Test func stopsWhenTheSessionIsGone() async throws {
        let transport = FakeTransport([])
        let env = environment(tempDirectory(), keychain: FakeKeychain(), transport: transport)
        try env.catalogStore.write(DoorCatalog(doors: [small]))
        let slept = SleepRecorder()
        await env.followUp(after: .open, on: small.identity, interval: .seconds(5), maximumChecks: 8, sleep: { await slept.record($0) }, onCheck: {})
        #expect(transport.requests.isEmpty)
        #expect(await slept.durations.count == 1, "it stops after the first check instead of waiting out all eight")
    }
}

actor SleepRecorder {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}

actor UpdateCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Suite struct CheckThrottleTests {
    @Test func aSecondCheckWithinTheIntervalIsSkippedUnlessForced() {
        var throttle = CheckThrottle(minimumInterval: 5)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let first = throttle.allow(at: start)
        let duplicate = throttle.allow(at: start.addingTimeInterval(0.3))
        let pulled = throttle.allow(at: start.addingTimeInterval(0.5), force: true)
        let tooSoon = throttle.allow(at: start.addingTimeInterval(4))
        let later = throttle.allow(at: start.addingTimeInterval(5.6))
        #expect(first)
        #expect(!duplicate, "opening the app fires both appear and become-active; only one check runs")
        #expect(pulled, "pull to refresh always checks")
        #expect(!tooSoon, "the forced check counts as the latest one")
        #expect(later)
    }
}
