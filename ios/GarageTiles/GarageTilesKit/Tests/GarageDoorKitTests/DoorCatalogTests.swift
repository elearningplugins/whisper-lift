import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

private func catalogDoor(_ name: String, serial: String, account: String = "account-1") -> CatalogDoor {
    CatalogDoor(identity: DoorIdentity(accountID: account, serial: serial), accountName: "Demo Home", name: name)
}

private let single = catalogDoor("Single Car Garage", serial: "s-1")
private let double = catalogDoor("Two Car Garage", serial: "s-2")

@Suite struct DoorAliasTests {
    @Test func singleCarDoorsGetSmallGarageNames() {
        #expect(DoorAliases.defaults(for: "Single Car Garage") == ["small door", "small garage", "one car garage", "single garage"])
        #expect(DoorAliases.defaults(for: "1-car garage") == ["small door", "small garage", "single garage"])
    }

    @Test func twoCarDoorsGetBigGarageNames() {
        #expect(DoorAliases.defaults(for: "Two Car Garage") == ["big door", "big garage", "double garage"])
        #expect(DoorAliases.defaults(for: "Double Garage") == ["big door", "big garage", "two car garage"])
        #expect(DoorAliases.defaults(for: "2 car garage") == ["big door", "big garage", "double garage"])
    }

    // An alias that only repeats the door's own name after normalization is dropped.
    @Test func aliasesNeverDuplicateTheName() {
        for name in ["Single Car Garage", "1-car garage", "Two Car Garage", "2 car garage", "Double Garage"] {
            #expect(!DoorAliases.defaults(for: name).contains { DoorCatalog.normalize($0) == DoorCatalog.normalize(name) })
        }
    }

    // Siri routes "open ... garage" to Apple Home, so each common door gets a nickname without the word garage.
    @Test func commonDoorsGetANicknameWithoutGarage() {
        for name in ["Single Car Garage", "Two Car Garage", "1-car garage", "Double Garage"] {
            #expect(DoorAliases.defaults(for: name).contains { !$0.contains("garage") }, "\(name)")
        }
    }

    @Test func otherNamesGetNoAliases() {
        #expect(DoorAliases.defaults(for: "Driveway Gate") == [])
        #expect(DoorAliases.defaults(for: "Shed") == [])
    }

    @Test func newDoorsCarryTheirDefaultAliases() {
        #expect(single.aliases == ["small door", "small garage", "one car garage", "single garage"])
        #expect(double.spokenNames == ["Two Car Garage", "big door", "big garage", "double garage"])
    }
}

@Suite struct DoorCatalogResolutionTests {
    private let catalog = DoorCatalog(doors: [single, double])

    @Test(arguments: [
        "Single Car Garage", "single car garage", "the single car garage", "small garage", "The Small Garage", "1 car garage", "one-car garage", "  single   garage ",
    ])
    func resolvesTheSingleCarDoor(_ spoken: String) {
        #expect(catalog.resolve(spoken) == .door(single))
    }

    @Test(arguments: ["Two Car Garage", "2 car garage", "big garage", "the big garage.", "double garage", "two-car garage"])
    func resolvesTheTwoCarDoor(_ spoken: String) {
        #expect(catalog.resolve(spoken) == .door(double))
    }

    // "big" alone now means the big garage; see SpokenPhraseCoverageTests.
    @Test(arguments: ["garage", "", "the", "three car garage", "front door"])
    func unknownNamesResolveToNothing(_ spoken: String) {
        #expect(catalog.resolve(spoken) == .noMatch)
    }

    @Test func aliasesSharedByTwoDoorsAreDroppedSoNothingIsAmbiguous() {
        let first = catalogDoor("Single Car Garage", serial: "a")
        let second = catalogDoor("Single Car Garage Annex", serial: "b", account: "account-2")
        let shared = DoorCatalog(doors: [first, CatalogDoor(identity: second.identity, accountName: "x", name: second.name, aliases: ["small garage"])])
        #expect(shared.resolve("small garage") == .noMatch)
        #expect(shared.resolve("single car garage annex") == .door(shared.doors[1]))
    }

    @Test func identicalNamesInTwoAccountsAreAmbiguous() {
        let first = catalogDoor("Garage", serial: "a")
        let second = catalogDoor("Garage", serial: "b", account: "account-2")
        #expect(DoorCatalog(doors: [first, second]).resolve("garage") == .ambiguous([first, second]))
    }

    @Test func lookupByIdentity() {
        #expect(catalog.door(for: double.identity) == double)
        #expect(catalog.door(for: DoorIdentity(accountID: "x", serial: "y")) == nil)
    }

    @Test func everySpokenNameOfAnUnambiguousCatalogResolvesToItsDoor() {
        forAll(iterations: 300, { rng in
            ["Single Car Garage", "Two Car Garage", "Driveway Gate", "Shed", "1 Car Garage", "Big Barn"].shuffled(using: &rng).prefix(Int.random(in: 1...4, using: &rng))
        }) { names in
            let doors = names.enumerated().map { catalogDoor($0.element, serial: "s\($0.offset)") }
            let catalog = DoorCatalog(doors: doors)
            return catalog.doors.allSatisfy { door in
                door.spokenNames.allSatisfy { spoken in
                    switch catalog.resolve(spoken) {
                    case .door(let found): found == door
                    case .ambiguous(let found): found.contains(door)
                    case .noMatch: false
                    }
                }
            }
        }
    }
}

@Suite struct DoorCatalogStoreTests {
    private func store() -> DoorCatalogStore {
        DoorCatalogStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Catalog-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func emptyBeforeFirstWrite() throws {
        #expect(try store().read() == DoorCatalog(doors: []))
    }

    @Test func roundTrips() throws {
        let store = store()
        try store.write(DoorCatalog(doors: [single, double]))
        #expect(try store.read() == DoorCatalog(doors: [single, double]))
    }

    @Test func malformedFileIsReported() throws {
        let store = store()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: store.fileURL)
        #expect(throws: DoorCatalogStore.StoreError.malformedData) { try store.read() }
    }
}

final class FakeDiscovery: DiscoveryAPI, @unchecked Sendable {
    var accountsResult: Result<[MyQAccount], any Error>
    var devicesByAccount: [String: [DoorDevice]]

    init(accounts: Result<[MyQAccount], any Error>, devices: [String: [DoorDevice]]) {
        accountsResult = accounts
        devicesByAccount = devices
    }

    func accounts() async throws -> [MyQAccount] { try accountsResult.get() }

    func devices(in account: MyQAccount) async throws -> [DoorDevice] {
        guard let devices = devicesByAccount[account.id] else { throw MyQError.httpStatus(500) }
        return devices
    }
}

private func device(_ name: String, serial: String, family: String = "garagedoor", account: MyQAccount) -> DoorDevice {
    DoorDevice(
        identity: DoorIdentity(accountID: account.id, serial: serial), accountName: account.name, name: name, family: family, state: .closed,
        online: true, unattendedOpenAllowed: true, unattendedCloseAllowed: true, vacationMode: false, activeFaults: [], lastServerUpdate: nil
    )
}

@Suite struct DoorDiscoveryTests {
    private let home = MyQAccount(id: "account-1", name: "Demo Home")

    @Test func keepsOnlyGarageDoorsSortedByName() async throws {
        let api = FakeDiscovery(accounts: .success([home]), devices: ["account-1": [
            device("Two Car Garage", serial: "door-2", account: home),
            device("Home", serial: "7384", family: "gateway", account: home),
            device("Single Car Garage", serial: "door-1", account: home),
        ]])
        let catalog = try await DoorDiscovery.discover(using: api)
        #expect(catalog.doors.map(\.name) == ["Single Car Garage", "Two Car Garage"])
        #expect(catalog.doors.map(\.identity.serial) == ["door-1", "door-2"])
        #expect(catalog.doors[0].accountName == "Demo Home")
        #expect(catalog.doors[1].aliases.first == "big door")
    }

    @Test func coversEveryAccount() async throws {
        let cabin = MyQAccount(id: "account-2", name: "Cabin")
        let api = FakeDiscovery(accounts: .success([home, cabin]), devices: [
            "account-1": [device("Single Car Garage", serial: "a", account: home)],
            "account-2": [device("Barn", serial: "b", account: cabin)],
        ])
        #expect(try await DoorDiscovery.discover(using: api).doors.map(\.name) == ["Barn", "Single Car Garage"])
    }

    @Test func failuresPropagateInsteadOfSavingAPartialCatalog() async {
        let api = FakeDiscovery(accounts: .success([home, MyQAccount(id: "missing", name: "x")]), devices: ["account-1": []])
        await #expect(throws: MyQError.httpStatus(500)) { try await DoorDiscovery.discover(using: api) }
        await #expect(throws: TokenError.signInRequired) {
            try await DoorDiscovery.discover(using: FakeDiscovery(accounts: .failure(TokenError.signInRequired), devices: [:]))
        }
    }
}

@Suite struct SessionImporterTests {
    private let token = String(repeating: "A1b2C3d4", count: 6)

    private func importer(_ store: MemoryTokenStore, _ refresher: FakeRefresher) -> SessionImporter {
        SessionImporter(store: store, tokens: TokenCoordinator(store: store, lock: ImmediateLock(), refresher: refresher))
    }

    @Test func validTokenIsSavedAndProvenWithOneRefresh() async throws {
        let store = MemoryTokenStore(nil)
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        try await importer(store, refresher).importToken("  \(token)\n")
        #expect(refresher.received == [token])
        #expect(try store.read()?.refreshToken == "r2")
        #expect(try store.read()?.accessToken == "a2")
    }

    @Test func invalidPasteIsRejectedBeforeAnyStoreOrNetworkUse() async throws {
        let store = MemoryTokenStore(nil)
        let refresher = FakeRefresher([])
        await #expect(throws: SessionImporter.ImportError.invalid(.looksLikeAccessHeader)) { try await importer(store, refresher).importToken("Bearer \(token)") }
        #expect(store.writes.isEmpty)
        #expect(refresher.calls == 0)
    }

    @Test func rejectedTokenIsRolledBackToThePreviousSession() async throws {
        let previous = TokenRecord(accessToken: "old-a", refreshToken: "old-r", accessTokenExpiry: .distantFuture, generation: 4, lastRefresh: nil)
        let store = MemoryTokenStore(previous)
        await #expect(throws: SessionImporter.ImportError.rejected) {
            try await importer(store, FakeRefresher([.failure(.invalidGrant)])).importToken(token)
        }
        #expect(try store.read() == previous)
    }

    @Test func rejectedFirstTokenLeavesNoSession() async throws {
        let store = MemoryTokenStore(nil)
        await #expect(throws: SessionImporter.ImportError.rejected) {
            try await importer(store, FakeRefresher([.failure(.invalidGrant)])).importToken(token)
        }
        #expect(try store.read() == nil)
    }

    @Test func unreachableMyQKeepsTheTokenForALaterRetry() async throws {
        let store = MemoryTokenStore(nil)
        await #expect(throws: SessionImporter.ImportError.unverified) {
            try await importer(store, FakeRefresher([.failure(.transport)])).importToken(token)
        }
        #expect(try store.read()?.refreshToken == token)
    }

    @Test func errorsNeverContainTheToken() {
        for error in [SessionImporter.ImportError.invalid(.tooShort), .rejected, .unverified] {
            #expect(!String(describing: error).contains("A1b2"))
        }
    }
}

@Suite struct SessionImportConcurrencyTests {
    private let newToken = String(repeating: "N3wT0ken", count: 6)

    private func lockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImportLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("refresh.lock")
    }

    // The widget is mid-refresh of the old session when the import starts; the import must win with the new token's own chain.
    @Test func importDuringAnOldSessionRefreshKeepsTheImportedChain() async throws {
        let url = try lockURL()
        let store = MemoryTokenStore(TokenRecord(accessToken: "old-a", refreshToken: "old-r", accessTokenExpiry: .distantPast, generation: 1, lastRefresh: nil))
        let refresher = KeyedRefresher(responses: [
            "old-r": RefreshResponse(accessToken: "old-a2", refreshToken: "old-r2", expiresIn: 3600),
            newToken: RefreshResponse(accessToken: "new-a", refreshToken: "new-r", expiresIn: 3600),
        ], delay: .milliseconds(200))
        let widget = TokenCoordinator(store: store, lock: FileLock(url: url), refresher: refresher)
        let app = TokenCoordinator(store: store, lock: FileLock(url: url), refresher: refresher)
        async let widgetToken = widget.validAccessToken()
        try await Task.sleep(for: .milliseconds(50))
        try await SessionImporter(store: store, tokens: app).importToken(newToken)
        _ = try await widgetToken
        let saved = try #require(try store.read())
        #expect(saved.refreshToken == "new-r")
        #expect(saved.accessToken == "new-a")
        #expect(refresher.received.contains(newToken))
    }

    @Test func rejectedImportDoesNotOverwriteANewerGeneration() async throws {
        let store = MemoryTokenStore(TokenRecord(accessToken: "a", refreshToken: "r", accessTokenExpiry: .distantFuture, generation: 3, lastRefresh: nil))
        let newer = TokenRecord(accessToken: "z", refreshToken: "zr", accessTokenExpiry: .distantFuture, generation: 9, lastRefresh: nil)
        let refresher = FakeRefresher([.failure(.invalidGrant)])
        refresher.beforeResponding = { store.replace(newer) }
        await #expect(throws: SessionImporter.ImportError.rejected) {
            try await SessionImporter(store: store, tokens: TokenCoordinator(store: store, lock: ImmediateLock(), refresher: refresher)).importToken(newToken)
        }
        #expect(try store.read() == newer)
    }

    @Test func importHoldsTheRefreshLockWhileWriting() async throws {
        let lock = RecordingLock()
        let store = LockCheckingStore(lock: lock)
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        try await SessionImporter(store: store, tokens: TokenCoordinator(store: store, lock: lock, refresher: refresher)).importToken(newToken)
        #expect(store.writesOutsideLock == 0)
        #expect(store.writes > 0)
    }
}

/** Answers each refresh token with its own response after a delay, like myQ issuing separate chains. */
final class KeyedRefresher: TokenRefresher, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: RefreshResponse]
    private let delay: Duration
    private(set) var received: [String] = []

    init(responses: [String: RefreshResponse], delay: Duration) {
        self.responses = responses
        self.delay = delay
    }

    func refresh(refreshToken: String) async throws -> RefreshResponse {
        lock.withLock { received.append(refreshToken) }
        try await Task.sleep(for: delay)
        guard let response = responses[refreshToken] else { throw MyQError.invalidGrant }
        return response
    }
}

final class RecordingLock: RefreshLock, @unchecked Sendable {
    private let mutex = NSLock()
    private var held = false
    var isHeld: Bool { mutex.withLock { held } }

    func withLock<T: Sendable>(timeout: Duration, _ body: @Sendable () async throws -> T) async throws -> T {
        mutex.withLock { held = true }
        defer { mutex.withLock { held = false } }
        return try await body()
    }
}

final class LockCheckingStore: RemovableTokenStore, @unchecked Sendable {
    private let lock: RecordingLock
    private let mutex = NSLock()
    private var record: TokenRecord?
    private(set) var writes = 0
    private(set) var writesOutsideLock = 0

    init(lock: RecordingLock) {
        self.lock = lock
    }

    func read() throws -> TokenRecord? { mutex.withLock { record } }

    func write(_ newRecord: TokenRecord) throws {
        let outside = !lock.isHeld
        mutex.withLock {
            record = newRecord
            writes += 1
            if outside { writesOutsideLock += 1 }
        }
    }

    func remove() throws { mutex.withLock { record = nil } }
}
