import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

private let start = Date(timeIntervalSince1970: 1_790_000_000)

private func record(_ access: String, _ refresh: String, expiresIn: TimeInterval, generation: Int = 1) -> TokenRecord {
    TokenRecord(accessToken: access, refreshToken: refresh, accessTokenExpiry: start.addingTimeInterval(expiresIn), generation: generation, lastRefresh: nil)
}

final class MemoryTokenStore: RemovableTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TokenRecord?
    private(set) var writes: [TokenRecord] = []
    var failWrites = false

    init(_ record: TokenRecord?) {
        stored = record
    }

    func read() throws -> TokenRecord? {
        lock.withLock { stored }
    }

    func write(_ record: TokenRecord) throws {
        try lock.withLock {
            if failWrites { throw TokenError.storeUnavailable }
            stored = record
            writes.append(record)
        }
    }

    // Simulates another process replacing the record outside this coordinator.
    func replace(_ record: TokenRecord) {
        lock.withLock { stored = record }
    }

    var failRemoves = false

    func remove() throws {
        try lock.withLock {
            if failRemoves { throw TokenError.storeUnavailable }
            stored = nil
        }
    }
}

final class FakeRefresher: TokenRefresher, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<RefreshResponse, MyQError>]
    private(set) var received: [String] = []
    var beforeResponding: (@Sendable () -> Void)?
    var delay: Duration = .zero

    init(_ responses: [Result<RefreshResponse, MyQError>]) {
        self.responses = responses
    }

    var calls: Int { lock.withLock { received.count } }

    func refresh(refreshToken: String) async throws -> RefreshResponse {
        let next: Result<RefreshResponse, MyQError> = lock.withLock {
            received.append(refreshToken)
            return responses.isEmpty ? .failure(.transport) : responses.removeFirst()
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        beforeResponding?()
        return try next.get()
    }
}

struct ImmediateLock: RefreshLock {
    var onAcquire: (@Sendable () -> Void)?
    var fails = false

    func withLock<T: Sendable>(timeout: Duration, _ body: @Sendable () async throws -> T) async throws -> T {
        if fails { throw TokenError.lockTimedOut }
        onAcquire?()
        return try await body()
    }
}

private func coordinator(_ store: MemoryTokenStore, _ refresher: FakeRefresher, lock: any RefreshLock = ImmediateLock(), now: Date = start) -> TokenCoordinator {
    TokenCoordinator(store: store, lock: lock, refresher: refresher, expiryMargin: 120, lockTimeout: .seconds(2), now: { now })
}

@Suite struct TokenCoordinatorTests {
    @Test func validTokenIsUsedWithoutRefreshing() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 121))
        let refresher = FakeRefresher([])
        #expect(try await coordinator(store, refresher).validAccessToken() == "a1")
        #expect(refresher.calls == 0)
    }

    @Test func tokenInsideTheMarginIsRefreshedAndPersistedFirst() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 120, generation: 4))
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        #expect(try await coordinator(store, refresher).validAccessToken() == "a2")
        #expect(refresher.received == ["r1"])
        let saved = try #require(try store.read())
        #expect(saved == TokenRecord(accessToken: "a2", refreshToken: "r2", accessTokenExpiry: start.addingTimeInterval(3600), generation: 5, lastRefresh: start))
        #expect(store.writes.count == 1)
    }

    @Test func missingReplacementRefreshTokenKeepsTheExistingOne() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0))
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: nil, expiresIn: 3600))])
        _ = try await coordinator(store, refresher).validAccessToken()
        #expect(try store.read()?.refreshToken == "r1")
    }

    @Test func emptyReplacementRefreshTokenKeepsTheExistingOne() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0))
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "", expiresIn: 3600))])
        _ = try await coordinator(store, refresher).validAccessToken()
        #expect(try store.read()?.refreshToken == "r1")
    }

    @Test func noRecordRequiresSignInWithoutAnyRequest() async {
        let refresher = FakeRefresher([])
        await #expect(throws: TokenError.signInRequired) { try await coordinator(MemoryTokenStore(nil), refresher).validAccessToken() }
        #expect(refresher.calls == 0)
    }

    @Test func anotherProcessRefreshedWhileWaitingForTheLock() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0, generation: 1))
        let refresher = FakeRefresher([])
        let lock = ImmediateLock(onAcquire: { store.replace(record("a2", "r2", expiresIn: 3600, generation: 2)) })
        #expect(try await coordinator(store, refresher, lock: lock).validAccessToken() == "a2")
        #expect(refresher.calls == 0)
        #expect(store.writes.isEmpty)
    }

    @Test func invalidGrantWithoutAdvanceRequiresSignIn() async throws {
        let original = record("a1", "r1", expiresIn: 0)
        let store = MemoryTokenStore(original)
        let refresher = FakeRefresher([.failure(.invalidGrant)])
        await #expect(throws: TokenError.signInRequired) { try await coordinator(store, refresher).validAccessToken() }
        #expect(refresher.calls == 1)
        #expect(try store.read() == original)
    }

    @Test func invalidGrantAfterAnotherProcessAdvancedUsesItsToken() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0, generation: 1))
        let refresher = FakeRefresher([.failure(.invalidGrant)])
        refresher.beforeResponding = { store.replace(record("a2", "r2", expiresIn: 3600, generation: 2)) }
        #expect(try await coordinator(store, refresher).validAccessToken() == "a2")
        #expect(refresher.calls == 1)
    }

    @Test func invalidGrantAfterAdvanceToAnExpiredRecordRetriesOnceWithTheNewRefreshToken() async throws {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0, generation: 1))
        let refresher = FakeRefresher([.failure(.invalidGrant), .success(RefreshResponse(accessToken: "a3", refreshToken: "r3", expiresIn: 3600))])
        refresher.beforeResponding = { if refresher.calls == 1 { store.replace(record("a2", "r2", expiresIn: 0, generation: 2)) } }
        #expect(try await coordinator(store, refresher).validAccessToken() == "a3")
        #expect(refresher.received == ["r1", "r2"])
        #expect(try store.read()?.generation == 3)
    }

    @Test func secondInvalidGrantStopsAndRequiresSignIn() async {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0, generation: 1))
        let refresher = FakeRefresher([.failure(.invalidGrant), .failure(.invalidGrant)])
        refresher.beforeResponding = { store.replace(record("a\(refresher.calls + 1)", "r\(refresher.calls + 1)", expiresIn: 0, generation: refresher.calls + 1)) }
        await #expect(throws: TokenError.signInRequired) { try await coordinator(store, refresher).validAccessToken() }
        #expect(refresher.calls == 2)
    }

    @Test func otherRefreshFailuresPropagateWithoutChangingTheStore() async throws {
        for failure in [MyQError.transport, .rateLimited(retryAfter: 30), .httpStatus(500)] {
            let original = record("a1", "r1", expiresIn: 0)
            let store = MemoryTokenStore(original)
            await #expect(throws: failure) { try await coordinator(store, FakeRefresher([.failure(failure)])).validAccessToken() }
            #expect(try store.read() == original)
        }
    }

    @Test func lockTimeoutNeverRefreshes() async {
        let refresher = FakeRefresher([])
        await #expect(throws: TokenError.lockTimedOut) {
            try await coordinator(MemoryTokenStore(record("a1", "r1", expiresIn: 0)), refresher, lock: ImmediateLock(fails: true)).validAccessToken()
        }
        #expect(refresher.calls == 0)
    }

    @Test func persistenceFailureReturnsNoToken() async {
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0))
        store.failWrites = true
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        await #expect(throws: TokenError.storeUnavailable) { try await coordinator(store, refresher).validAccessToken() }
    }

    @Test func appAndWidgetRefreshingTogetherCallMyQOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("refresh.lock")
        let store = MemoryTokenStore(record("a1", "r1", expiresIn: 0))
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        refresher.delay = .milliseconds(100)
        let app = coordinator(store, refresher, lock: FileLock(url: lockURL))
        let widget = coordinator(store, refresher, lock: FileLock(url: lockURL))
        async let first = app.validAccessToken()
        async let second = widget.validAccessToken()
        #expect(try await [first, second] == ["a2", "a2"])
        #expect(refresher.calls == 1)
    }
}

@Suite struct TokenRecordTests {
    private let secret = TokenRecord(accessToken: "access-SECRET", refreshToken: "refresh-SECRET", accessTokenExpiry: start, generation: 2, lastRefresh: start)

    @Test func everyTextualFormRedactsBothTokens() {
        var dumped = ""
        dump(secret, to: &dumped)
        for text in [String(describing: secret), String(reflecting: secret), "\(secret)", dumped, String(describing: [secret]), String(describing: Optional(secret))] {
            #expect(!text.contains("SECRET"), "\(text)")
        }
    }

    @Test func codableRoundTripKeepsTheTokensForTheKeychain() throws {
        let data = try JSONEncoder().encode(secret)
        #expect(try JSONDecoder().decode(TokenRecord.self, from: data) == secret)
    }

    @Test func errorsNeverCarryTokens() {
        for error in [TokenError.signInRequired, .lockTimedOut, .storeUnavailable] as [any Error] {
            #expect(!String(describing: error).contains("SECRET"))
        }
    }

    @Test func refreshesAlwaysAdvanceTheGenerationAndKeepARefreshToken() async throws {
        try await forAllAsync(iterations: 200, { rng in
            (Int.random(in: 0...1000, using: &rng), [nil, "", "r-new"].randomElement(using: &rng)!, Double.random(in: 1...86_400, using: &rng))
        }) { generation, replacement, lifetime in
            let store = MemoryTokenStore(record("a", "r-old", expiresIn: 0, generation: generation))
            let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: replacement, expiresIn: lifetime))])
            _ = try await coordinator(store, refresher).validAccessToken()
            let saved = try #require(try store.read())
            return saved.generation == generation + 1 && !saved.refreshToken.isEmpty && saved.accessTokenExpiry == start.addingTimeInterval(lifetime)
        }
    }
}

@Suite struct FileLockTests {
    private func lockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileLock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("refresh.lock")
    }

    @Test func holdersNeverOverlap() async throws {
        let url = try lockURL()
        let tracker = OverlapTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await FileLock(url: url).withLock(timeout: .seconds(10)) {
                        tracker.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        tracker.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(tracker.maximum == 1)
        #expect(tracker.total == 8)
    }

    @Test func timesOutWhileAnotherProcessHoldsTheLock() async throws {
        let url = try lockURL()
        let holder = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)
        await #expect(throws: TokenError.lockTimedOut) {
            try await FileLock(url: url).withLock(timeout: .milliseconds(50)) { 1 }
        }
    }

    @Test func unexpectedLockErrorFailsImmediately() async throws {
        let attempts = Counter()
        let lock = FileLock(url: try lockURL()) { _ in
            attempts.add()
            return EBADF
        }
        await #expect(throws: TokenError.storeUnavailable) { try await lock.withLock(timeout: .seconds(30)) { 1 } }
        #expect(attempts.value == 1)
    }

    @Test func interruptedLockAttemptIsRetried() async throws {
        let attempts = Counter()
        let lock = FileLock(url: try lockURL()) { descriptor in
            attempts.add()
            return attempts.value == 1 ? EINTR : (flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? 0 : errno)
        }
        #expect(try await lock.withLock(timeout: .seconds(30)) { 7 } == 7)
        #expect(attempts.value == 2)
    }

    @Test func releasesTheLockWhenTheBodyThrows() async throws {
        let url = try lockURL()
        await #expect(throws: TokenError.signInRequired) {
            try await FileLock(url: url).withLock(timeout: .seconds(1)) { () async throws -> Int in throw TokenError.signInRequired }
        }
        #expect(try await FileLock(url: url).withLock(timeout: .milliseconds(50)) { 7 } == 7)
    }
}

final class OverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    private(set) var total = 0

    func enter() {
        lock.withLock {
            active += 1
            total += 1
            maximum = max(maximum, active)
        }
    }

    func leave() {
        lock.withLock { active -= 1 }
    }
}


/** Records whether the refresh lock was held at the moment the token was removed. */
final class RemovalCheckingStore: RemovableTokenStore, @unchecked Sendable {
    private let lock: RecordingLock
    private let mutex = NSLock()
    private var record: TokenRecord?
    private(set) var removedWhileLocked: [Bool] = []

    init(_ record: TokenRecord?, lock: RecordingLock) {
        self.record = record
        self.lock = lock
    }

    func read() throws -> TokenRecord? { mutex.withLock { record } }
    func write(_ newRecord: TokenRecord) throws { mutex.withLock { record = newRecord } }

    func remove() throws {
        let held = lock.isHeld
        mutex.withLock {
            record = nil
            removedWhileLocked.append(held)
        }
    }
}

/** A store that can be read and written but not removed, as a guard for misconfigured callers. */
struct UnremovableTokenStore: TokenStore {
    func read() throws -> TokenRecord? { nil }
    func write(_ record: TokenRecord) throws {}
}

@Suite struct SignOutTests {
    @Test func signOutRemovesTheTokenUnderTheRefreshLock() async throws {
        let lock = RecordingLock()
        let store = RemovalCheckingStore(record("a", "r", expiresIn: 3600), lock: lock)
        try await TokenCoordinator(store: store, lock: lock, refresher: FakeRefresher([]), now: { start }).signOut()
        #expect(try store.read() == nil)
        #expect(store.removedWhileLocked == [true])
    }

    @Test func aRemovalFailureIsReportedAndKeepsTheSession() async throws {
        let original = record("a", "r", expiresIn: 3600)
        let store = MemoryTokenStore(original)
        store.failRemoves = true
        await #expect(throws: TokenError.storeUnavailable) { try await coordinator(store, FakeRefresher([])).signOut() }
        #expect(try store.read() == original)
    }

    @Test func aBusyLockIsReportedAndKeepsTheSession() async throws {
        let original = record("a", "r", expiresIn: 3600)
        let store = MemoryTokenStore(original)
        await #expect(throws: TokenError.lockTimedOut) { try await coordinator(store, FakeRefresher([]), lock: ImmediateLock(fails: true)).signOut() }
        #expect(try store.read() == original)
    }

    @Test func aStoreThatCannotRemoveIsReported() async {
        let coordinator = TokenCoordinator(store: UnremovableTokenStore(), lock: ImmediateLock(), refresher: FakeRefresher([]), now: { start })
        await #expect(throws: TokenError.storeUnavailable) { try await coordinator.signOut() }
    }

    @Test func aRefreshQueuedBehindSignOutCannotBringTheSessionBack() async throws {
        let store = MemoryTokenStore(record("expired", "r", expiresIn: -10))
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "revived", refreshToken: "r2", expiresIn: 3600))])
        let tokens = coordinator(store, refresher)
        try await tokens.signOut()
        await #expect(throws: TokenError.signInRequired) { try await tokens.refreshAfterRejection(of: "expired") }
        await #expect(throws: TokenError.signInRequired) { try await tokens.validAccessToken() }
        #expect(refresher.calls == 0)
        #expect(try store.read() == nil)
    }
}
