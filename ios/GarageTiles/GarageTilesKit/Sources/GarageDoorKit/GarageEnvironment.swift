import Foundation

/** Wires the Keychain, App Group files, refresh lock, myQ client and command service the same way for the app, Siri intents and widget. */
public struct GarageEnvironment: Sendable {
    public static let appGroupInfoKey = "GarageTilesAppGroup"
    public static let keychainGroupInfoKey = "GarageTilesKeychainGroup"

    /** Why signing out stopped; each case says what is still on the device. */
    public enum SignOutError: Error, Equatable, Sendable, CustomStringConvertible {
        case sessionNotRemoved
        case commandInProgress
        case localDataNotRemoved

        public var description: String {
            switch self {
            case .sessionNotRemoved: "The session couldn't be removed. Unlock the iPhone and try again."
            case .commandInProgress: "Signed out, but a door command is still finishing. Tap Sign out again in a few seconds to delete the saved door data."
            case .localDataNotRemoved: "Signed out, but the saved door data couldn't be deleted. Tap Sign out again."
            }
        }
    }

    public enum SetupError: Error, Equatable, Sendable {
        case missingAppGroup
        case missingKeychainGroup
        case containerUnavailable
    }

    public let catalogStore: DoorCatalogStore
    public let snapshotStore: DoorSnapshotStore
    public let tokenStore: KeychainTokenStore
    public let refreshLockURL: URL
    public let tokens: TokenCoordinator
    public let client: MyQClient
    public let importer: SessionImporter
    public let trafficLog: TrafficLog
    let commands: DoorCommandService
    let commandLock: FileCommandLock
    let now: @Sendable () -> Date
    let transport: any HTTPTransport
    let configuration: MyQConfiguration?

    public init(
        dataDirectory: URL,
        keychainGroup: String,
        transport: any HTTPTransport = URLSessionTransport(),
        keychain: any KeychainBackend = SecItemBackend(),
        configuration: MyQConfiguration? = nil,
        profile: CommandProfile = .interactive,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        catalogStore = DoorCatalogStore(directory: dataDirectory)
        snapshotStore = DoorSnapshotStore(directory: dataDirectory)
        tokenStore = KeychainTokenStore(accessGroup: keychainGroup, backend: keychain)
        refreshLockURL = dataDirectory.appendingPathComponent("refresh.lock", isDirectory: false)
        trafficLog = TrafficLog(directory: dataDirectory)
        let transport = MeteredTransport(inner: transport, log: trafficLog, now: now)
        self.transport = transport
        self.configuration = configuration
        tokens = TokenCoordinator(
            store: tokenStore, lock: DirectoryFileLock(directory: dataDirectory, url: refreshLockURL), refresher: MyQTokenRefresher(transport: transport), now: now
        )
        client = MyQClient(transport: transport, tokens: tokens)
        importer = SessionImporter(store: tokenStore, tokens: tokens)
        commandLock = FileCommandLock(directory: dataDirectory)
        self.now = now
        commands = DoorCommandService(
            api: client, snapshots: snapshotStore, commandLock: commandLock, followUpReads: profile.followUpReads, now: now, sleep: sleep
        )
    }

    /** Builds the environment from the bundle's Info.plist App Group and Keychain group, as both the app and the widget extension do. */
    public static func live(bundle: Bundle = .main, profile: CommandProfile = .interactive) throws -> GarageEnvironment {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, group.hasPrefix("group."), !group.contains("$(") else {
            throw SetupError.missingAppGroup
        }
        guard let keychainGroup = validatedKeychainGroup(bundle.object(forInfoDictionaryKey: keychainGroupInfoKey)) else {
            throw SetupError.missingKeychainGroup
        }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw SetupError.containerUnavailable }
        // Only sign-in needs the configuration, so Siri and door commands keep working without it.
        let configuration = try? MyQConfiguration(info: bundle.infoDictionary ?? [:])
        return GarageEnvironment(
            dataDirectory: container.appendingPathComponent("Doors", isDirectory: true), keychainGroup: keychainGroup, configuration: configuration, profile: profile
        )
    }

    /** Accepts only a fully expanded "TEAMID.bundle.prefix" access group. */
    public static func validatedKeychainGroup(_ raw: Any?) -> String? {
        guard let value = raw as? String, value == value.trimmingCharacters(in: .whitespacesAndNewlines), value.contains("."), !value.contains("$(") else {
            return nil
        }
        return value
    }

    /** Runs one Siri or widget request against a door from the catalog and returns the outcome with its spoken dialog. */
    public func perform(_ request: DoorRequest, on identity: DoorIdentity) async -> (outcome: CommandOutcome, dialog: String) {
        guard let door = (try? catalogStore.read())?.door(for: identity) else {
            let outcome = CommandOutcome.refused(.missing)
            return (outcome, outcome.dialog(doorName: "that garage door"))
        }
        let outcome = await commands.perform(request, on: identity, accountName: door.accountName)
        return (outcome, outcome.dialog(doorName: door.name))
    }

    /** Runs the in-app myQ sign-in through the metered transport and saves the new session to the shared Keychain. */
    public func signIn(with authenticator: any WebAuthenticating, makeState: @escaping @Sendable () -> String = { PKCE.randomToken() }) async throws {
        try await MyQSignInFlow(transport: transport, tokens: tokens, authenticator: authenticator, configuration: configuration, makeState: makeState).signIn()
    }

    /** Signs out completely: the session goes first, under the refresh lock, so nothing new can act; then, once no door command is running, every saved door state, the door list and the request log. */
    public func signOut() async throws {
        do {
            try await tokens.signOut()
        } catch {
            throw SignOutError.sessionNotRemoved
        }
        let doors = ((try? catalogStore.read()) ?? DoorCatalog(doors: [])).doors.map(\.identity)
        try await whileNoCommandRuns(doors[...]) {
            do {
                try snapshotStore.removeAll()
                try catalogStore.remove()
                try trafficLog.remove()
            } catch {
                throw SignOutError.localDataNotRemoved
            }
        }
    }

    // Holds every listed door's command lock at once, so a command that started before sign-out finishes before its data is deleted.
    private func whileNoCommandRuns(_ doors: ArraySlice<DoorIdentity>, _ body: @escaping @Sendable () throws -> Void) async throws {
        guard let door = doors.first else { return try body() }
        do {
            try await commandLock.withDoorLock(door) { try await whileNoCommandRuns(doors.dropFirst(), body) }
        } catch CommandLockError.busy {
            throw SignOutError.commandInProgress
        } catch CommandLockError.unavailable {
            throw SignOutError.localDataNotRemoved
        }
    }

    /** What a status check found, worst result first when accounts differ. */
    public enum StatusRefresh: Equatable, Sendable {
        case updated
        case noDoors
        case signInRequired
        case rateLimited
        case unreachable
    }

    /** Reads every saved door's live state, one request per account and never a command, so the app never shows an old state as current. */
    public func refreshStatus() async -> StatusRefresh {
        guard let catalog = try? catalogStore.read(), !catalog.doors.isEmpty else { return .noDoors }
        var result = StatusRefresh.updated
        let accounts = Dictionary(grouping: catalog.doors, by: \.identity.accountID).sorted { $0.key < $1.key }
        for (accountID, doors) in accounts {
            let devices: [DoorDevice]
            do {
                devices = try await client.devices(in: MyQAccount(id: accountID, name: doors[0].accountName))
            } catch TokenError.signInRequired {
                await mark(doors, .signInRequired)
                result = .signInRequired
                continue
            } catch MyQError.rateLimited {
                await mark(doors, .rateLimited)
                if result == .updated { result = .rateLimited }
                continue
            } catch {
                await mark(doors, .unreachable)
                if result == .updated || result == .rateLimited { result = .unreachable }
                continue
            }
            for door in doors {
                guard case .found(let device) = DoorCommandService.lookup(door.identity, in: devices) else { continue }
                let fetchedAt = now()
                await whileDoorIsIdle(door) { cached in
                    DoorSnapshot(device: device, fetchedAt: fetchedAt, lastCommand: cached?.lastCommand, lastCommandAt: cached?.lastCommandAt, problem: nil)
                }
            }
        }
        return result
    }

    /** After myQ accepts a command, checks the door every interval until it stops moving or the limit is reached; reads only, never a command, and the caller redraws after each check. */
    public func followUp(
        after action: DoorAction, on door: DoorIdentity, interval: Duration = .seconds(5), maximumChecks: Int = 8,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }, onCheck: @escaping @Sendable () async -> Void = {}
    ) async {
        for _ in 0..<maximumChecks {
            await sleep(interval)
            if Task.isCancelled { return }
            let result = await refreshStatus()
            await onCheck()
            if result == .signInRequired || result == .noDoors { return }
            guard let state = (try? snapshotStore.snapshot(for: door))??.device.state else { continue }
            // Any state other than moving ends the watch, including a door that reversed instead of reaching the action's target.
            if state != .opening && state != .closing { return }
        }
    }

    private func mark(_ doors: [CatalogDoor], _ problem: DoorProblem) async {
        for door in doors {
            await whileDoorIsIdle(door) { cached in cached?.marking(problem) }
        }
    }

    // Writes under the door's command lock and skips a door whose command is running, so its uncertain-command record is never overwritten.
    private func whileDoorIsIdle(_ door: CatalogDoor, _ update: @escaping @Sendable (DoorSnapshot?) -> DoorSnapshot?) async {
        _ = try? await commandLock.withDoorLock(door.identity) {
            let cached = try? snapshotStore.snapshot(for: door.identity)
            if let next = update(cached) { try? snapshotStore.upsert(next) }
        }
    }

    /** Re-reads every garage door from myQ and replaces the catalog. */
    public func discoverDoors() async throws -> DoorCatalog {
        let catalog = try await DoorDiscovery.discover(using: client)
        try catalogStore.write(catalog)
        return catalog
    }
}

/** A FileLock that first creates its directory, since the App Group's Doors folder may not exist yet. */
struct DirectoryFileLock: RefreshLock {
    let directory: URL
    let url: URL

    func withLock<T: Sendable>(timeout: Duration, _ body: @Sendable () async throws -> T) async throws -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try await FileLock(url: url).withLock(timeout: timeout, body)
    }
}
