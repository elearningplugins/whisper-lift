import Foundation

/** Returns a usable access token, refreshing under an interprocess lock so the app and widget never both rotate the token (PLAN.md Phase 4). */
public struct TokenCoordinator: AccessTokenProvider {
    let store: any TokenStore
    let lock: any RefreshLock
    let refresher: any TokenRefresher
    let expiryMargin: TimeInterval
    let lockTimeout: Duration
    let now: @Sendable () -> Date

    public init(
        store: any TokenStore,
        lock: any RefreshLock,
        refresher: any TokenRefresher,
        expiryMargin: TimeInterval = 120,
        lockTimeout: Duration = .seconds(5),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.lock = lock
        self.refresher = refresher
        self.expiryMargin = expiryMargin
        self.lockTimeout = lockTimeout
        self.now = now
    }

    public func validAccessToken() async throws -> String {
        guard let initial = try readStore() else { throw TokenError.signInRequired }
        if isUsable(initial) { return initial.accessToken }
        return try await refreshUnderLock(rejected: nil)
    }

    /** Refreshes after myQ rejected a token, unless another process has already replaced it. */
    public func refreshAfterRejection(of token: String) async throws -> String {
        try await refreshUnderLock(rejected: token)
    }

    public enum ImportResult: Equatable, Sendable {
        case verified
        case rejected
        case unverified
    }

    /** Replaces the session with an imported refresh token and proves it with one refresh, all under the refresh lock; a rejected token is rolled back only if no other process has written since. */
    public func importRefreshToken(_ token: String) async throws -> ImportResult {
        try await lock.withLock(timeout: lockTimeout) {
            let previous = try readStore()
            let imported = TokenImport.record(refreshToken: token, replacing: previous)
            try writeStore(imported)
            do {
                _ = try await refreshAndPersist(imported)
                return .verified
            } catch MyQError.invalidGrant {
                if let current = try readStore(), current.generation == imported.generation {
                    if let previous {
                        try writeStore(previous)
                    } else if let removable = store as? any RemovableTokenStore {
                        do { try removable.remove() } catch { throw TokenError.storeUnavailable }
                    }
                }
                return .rejected
            } catch let error as TokenError {
                throw error
            } catch {
                return .unverified
            }
        }
    }

    /** Saves a freshly signed-in session as the next generation, under the refresh lock so no concurrent refresh can interleave. */
    public func adoptSession(_ response: RefreshResponse) async throws {
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else { throw MyQError.malformedResponse }
        try await lock.withLock(timeout: lockTimeout) {
            let previous = try readStore()
            let signedInAt = now()
            try writeStore(TokenRecord(
                accessToken: response.accessToken, refreshToken: refreshToken, accessTokenExpiry: signedInAt.addingTimeInterval(response.expiresIn),
                generation: (previous?.generation ?? 0) + 1, lastRefresh: signedInAt
            ))
        }
    }

    /** Deletes the session under the refresh lock, so a refresh already running finishes first and none can write the session back afterwards. */
    public func signOut() async throws {
        guard let removable = store as? any RemovableTokenStore else { throw TokenError.storeUnavailable }
        try await lock.withLock(timeout: lockTimeout) {
            do {
                try removable.remove()
            } catch {
                throw TokenError.storeUnavailable
            }
        }
    }

    private func writeStore(_ record: TokenRecord) throws {
        do {
            try store.write(record)
        } catch {
            throw TokenError.storeUnavailable
        }
    }

    private func refreshUnderLock(rejected: String?) async throws -> String {
        try await lock.withLock(timeout: lockTimeout) {
            // Re-read under the lock: another process may already have refreshed.
            guard var current = try readStore() else { throw TokenError.signInRequired }
            if isUsable(current), current.accessToken != rejected { return current.accessToken }
            var retried = false
            while true {
                do {
                    return try await refreshAndPersist(current)
                } catch MyQError.invalidGrant {
                    // Retry once only if another process advanced the generation; otherwise the session is gone.
                    guard !retried, let latest = try readStore(), latest.generation > current.generation else { throw TokenError.signInRequired }
                    if isUsable(latest) { return latest.accessToken }
                    current = latest
                    retried = true
                }
            }
        }
    }

    private func refreshAndPersist(_ current: TokenRecord) async throws -> String {
        let response = try await refresher.refresh(refreshToken: current.refreshToken)
        let replacement = response.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? current.refreshToken
        let refreshedAt = now()
        let next = TokenRecord(
            accessToken: response.accessToken,
            refreshToken: replacement,
            accessTokenExpiry: refreshedAt.addingTimeInterval(response.expiresIn),
            generation: current.generation + 1,
            lastRefresh: refreshedAt
        )
        // Persist before returning so no request ever uses a token the store does not hold.
        do {
            try store.write(next)
        } catch {
            throw TokenError.storeUnavailable
        }
        return next.accessToken
    }

    private func isUsable(_ record: TokenRecord) -> Bool {
        record.accessTokenExpiry.timeIntervalSince(now()) > expiryMargin
    }

    private func readStore() throws -> TokenRecord? {
        do {
            return try store.read()
        } catch {
            throw TokenError.storeUnavailable
        }
    }
}

/** An advisory flock on a file in the App Group, shared by the app and widget processes. */
public struct FileLock: RefreshLock {
    public let url: URL
    // Attempts a non-blocking exclusive lock and returns 0 or the errno; replaceable so tests can inject lock failures.
    let tryLock: @Sendable (Int32) -> Int32

    public init(url: URL) {
        self.init(url: url) { flock($0, LOCK_EX | LOCK_NB) == 0 ? 0 : errno }
    }

    init(url: URL, tryLock: @escaping @Sendable (Int32) -> Int32) {
        self.url = url
        self.tryLock = tryLock
    }

    public func withLock<T: Sendable>(timeout: Duration, _ body: @Sendable () async throws -> T) async throws -> T {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TokenError.storeUnavailable }
        defer { close(descriptor) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while case let code = tryLock(descriptor), code != 0 {
            guard code == EWOULDBLOCK || code == EINTR else { throw TokenError.storeUnavailable }
            guard clock.now < deadline else { throw TokenError.lockTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
