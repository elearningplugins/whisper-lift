import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/** Sends one request without following redirects; failures to get any response throw MyQError.transport. */
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public protocol AccessTokenProvider: Sendable {
    func validAccessToken() async throws -> String
    func refreshAfterRejection(of token: String) async throws -> String
}

public enum CommandError: Error, Equatable, Sendable {
    /** The PUT may or may not have been accepted; it was not repeated, and live state must be re-read before any new decision. */
    case outcomeUnknown
}

/** Reads accounts and devices and sends single door commands, following the PLAN.md Phase 5 request policy. */
public struct MyQClient: Sendable {
    let transport: any HTTPTransport
    let tokens: any AccessTokenProvider

    public init(transport: any HTTPTransport, tokens: any AccessTokenProvider) {
        self.transport = transport
        self.tokens = tokens
    }

    public func accounts() async throws -> [MyQAccount] {
        try MyQAccount.parseAccounts(try await get(MyQMetadata.url(host: MyQMetadata.accountsHost, path: "/api/v6.0/accounts")))
    }

    public func devices(in account: MyQAccount) async throws -> [DoorDevice] {
        let url = MyQMetadata.url(host: MyQMetadata.devicesHost, path: "/api/v6.2/Accounts/\(MyQMetadata.escape(account.id))/Devices")
        return try DoorDevice.parseDevices(try await get(url), account: account)
    }

    /** Sends exactly one PUT; anything but a 2xx response, including 401, is an unknown outcome and is never retried. */
    public func send(_ action: DoorAction, to door: DoorIdentity) async throws {
        let path = "/api/v6.0/accounts/\(MyQMetadata.escape(door.accountID))/door_openers/\(MyQMetadata.escape(door.serial))/\(action.rawValue)"
        let token = try await tokens.validAccessToken()
        let request = HTTPRequest(method: "PUT", url: MyQMetadata.url(host: MyQMetadata.commandsHost, path: path), headers: authorized(token))
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw CommandError.outcomeUnknown
        }
        guard (200..<300).contains(response.status) else { throw CommandError.outcomeUnknown }
    }

    private func get(_ url: URL) async throws -> Data {
        let token = try await tokens.validAccessToken()
        var response = try await transport.send(HTTPRequest(method: "GET", url: url, headers: authorized(token)))
        if response.status == 401 || response.status == 403 {
            let replacement = try await tokens.refreshAfterRejection(of: token)
            response = try await transport.send(HTTPRequest(method: "GET", url: url, headers: authorized(replacement)))
            if response.status == 401 || response.status == 403 { throw MyQError.unauthorized }
        }
        try Self.check(response)
        return response.body
    }

    static func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 429: throw MyQError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init).flatMap { $0 >= 0 ? $0 : nil })
        default: throw MyQError.httpStatus(response.status)
        }
    }

    private func authorized(_ token: String) -> [String: String] {
        MyQMetadata.commonHeaders().merging(["Authorization": "Bearer \(token)"]) { _, new in new }
    }
}

/** Exchanges a refresh token at the myQ identity endpoint; errors never include the response body. */
public struct MyQTokenRefresher: TokenRefresher {
    let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func refresh(refreshToken: String) async throws -> RefreshResponse {
        let form = [
            ("client_id", MyQMetadata.oauthClientID),
            ("scope", MyQMetadata.oauthScope),
            ("redirect_uri", MyQMetadata.oauthRedirectURI),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ].map { "\(MyQMetadata.escape($0.0))=\(MyQMetadata.escape($0.1))" }.joined(separator: "&")
        let headers = MyQMetadata.commonHeaders().merging(["Content-Type": "application/x-www-form-urlencoded"]) { _, new in new }
        let response = try await transport.send(
            HTTPRequest(method: "POST", url: MyQMetadata.url(host: MyQMetadata.identityHost, path: "/connect/token"), headers: headers, body: Data(form.utf8))
        )
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        if [400, 401, 403].contains(response.status) {
            throw (object?["error"] as? String) == "invalid_grant" ? MyQError.invalidGrant : MyQError.unauthorized
        }
        try MyQClient.check(response)
        guard
            let object,
            let access = object["access_token"] as? String, !access.isEmpty,
            let lifetime = object["expires_in"] as? NSNumber, CFGetTypeID(lifetime) != CFBooleanGetTypeID(), lifetime.doubleValue > 0
        else { throw MyQError.malformedResponse }
        return RefreshResponse(accessToken: access, refreshToken: object["refresh_token"] as? String, expiresIn: lifetime.doubleValue)
    }
}
