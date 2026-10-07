import Foundation

/** The one shared token record, stored whole in the Keychain; every textual form redacts both tokens. */
public struct TokenRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let refreshToken: String
    public let accessTokenExpiry: Date
    public let generation: Int
    public let lastRefresh: Date?

    public init(accessToken: String, refreshToken: String, accessTokenExpiry: Date, generation: Int, lastRefresh: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiry = accessTokenExpiry
        self.generation = generation
        self.lastRefresh = lastRefresh
    }

    public var description: String {
        "TokenRecord(generation: \(generation), accessTokenExpiry: \(accessTokenExpiry), tokens: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["generation": generation, "accessTokenExpiry": accessTokenExpiry, "tokens": "<redacted>"], displayStyle: .struct)
    }
}

public enum TokenError: Error, Equatable, Sendable {
    case signInRequired
    case lockTimedOut
    case storeUnavailable
}

public protocol TokenStore: Sendable {
    func read() throws -> TokenRecord?
    func write(_ record: TokenRecord) throws
}

public protocol RefreshLock: Sendable {
    func withLock<T: Sendable>(timeout: Duration, _ body: @Sendable () async throws -> T) async throws -> T
}

public struct RefreshResponse: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: TimeInterval

    public init(accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
    }
}

public protocol TokenRefresher: Sendable {
    func refresh(refreshToken: String) async throws -> RefreshResponse
}
