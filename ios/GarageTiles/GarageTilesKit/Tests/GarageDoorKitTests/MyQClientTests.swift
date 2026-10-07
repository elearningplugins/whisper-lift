import Foundation
import Testing
@testable import GarageDoorKit

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<HTTPResponse, MyQError>]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [Result<HTTPResponse, MyQError>]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let next: Result<HTTPResponse, MyQError> = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? .failure(.transport) : responses.removeFirst()
        }
        return try next.get()
    }
}

final class FakeTokens: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var current = "token-1"
    private(set) var rejections: [String] = []
    var rejectionResult: Result<String, TokenError> = .success("token-2")

    func validAccessToken() async throws -> String {
        lock.withLock { current }
    }

    func refreshAfterRejection(of token: String) async throws -> String {
        let result = lock.withLock {
            rejections.append(token)
            return rejectionResult
        }
        let next = try result.get()
        lock.withLock { current = next }
        return next
    }
}

private func ok(_ json: String = "{}", status: Int = 200) -> Result<HTTPResponse, MyQError> {
    .success(HTTPResponse(status: status, headers: [:], body: Data(json.utf8)))
}

private func status(_ code: Int, headers: [String: String] = [:]) -> Result<HTTPResponse, MyQError> {
    .success(HTTPResponse(status: code, headers: headers, body: Data()))
}

private let door = DoorIdentity(accountID: "acc/1", serial: "CG 1")
private let account = MyQAccount(id: "acc/1", name: "Home")

@Suite struct MyQClientReadTests {
    @Test func readsAccountsWithPinnedHeaders() async throws {
        let transport = FakeTransport([ok(#"{"accounts":[{"id":"acc/1","name":"Home"}]}"#)])
        let accounts = try await MyQClient(transport: transport, tokens: FakeTokens()).accounts()
        #expect(accounts == [account])
        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://accounts.myq-cloud.com/api/v6.0/accounts")
        #expect(request.headers["Authorization"] == "Bearer token-1")
        #expect(request.headers["App-Version"] == MyQMetadata.appVersion)
        #expect(request.headers["BrandId"] == MyQMetadata.brandID)
        #expect(request.headers["User-Agent"] == MyQMetadata.userAgent)
        #expect(request.body == nil)
    }

    @Test func readsDevicesWithAnEscapedAccountID() async throws {
        let transport = FakeTransport([ok(#"{"items":[]}"#)])
        _ = try await MyQClient(transport: transport, tokens: FakeTokens()).devices(in: account)
        #expect(transport.requests.first?.url.absoluteString == "https://devices.myq-cloud.com/api/v6.2/Accounts/acc%2F1/Devices")
    }

    @Test(arguments: [401, 403])
    func readRefreshesOnceAfterRejection(_ code: Int) async throws {
        let transport = FakeTransport([status(code), ok(#"{"accounts":[]}"#)])
        let tokens = FakeTokens()
        #expect(try await MyQClient(transport: transport, tokens: tokens).accounts() == [])
        #expect(tokens.rejections == ["token-1"])
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test func secondRejectionIsUnauthorizedWithoutAThirdRequest() async {
        let transport = FakeTransport([status(401), status(401)])
        await #expect(throws: MyQError.unauthorized) { try await MyQClient(transport: transport, tokens: FakeTokens()).accounts() }
        #expect(transport.requests.count == 2)
    }

    @Test func refreshFailureDuringRetryPropagates() async {
        let tokens = FakeTokens()
        tokens.rejectionResult = .failure(.signInRequired)
        let transport = FakeTransport([status(401)])
        await #expect(throws: TokenError.signInRequired) { try await MyQClient(transport: transport, tokens: tokens).accounts() }
        #expect(transport.requests.count == 1)
    }

    @Test func rateLimitIsNeverRetriedAndKeepsRetryAfter() async {
        let transport = FakeTransport([status(429, headers: ["Retry-After": "30"])])
        await #expect(throws: MyQError.rateLimited(retryAfter: 30)) { try await MyQClient(transport: transport, tokens: FakeTokens()).accounts() }
        #expect(transport.requests.count == 1)
    }

    @Test func rateLimitWithoutAUsableRetryAfter() async {
        let transport = FakeTransport([status(429, headers: ["Retry-After": "soon"])])
        await #expect(throws: MyQError.rateLimited(retryAfter: nil)) { try await MyQClient(transport: transport, tokens: FakeTokens()).accounts() }
    }

    @Test(arguments: [500, 502, 302, 404])
    func unexpectedStatusesFailWithoutRetry(_ code: Int) async {
        let transport = FakeTransport([status(code)])
        await #expect(throws: MyQError.httpStatus(code)) { try await MyQClient(transport: transport, tokens: FakeTokens()).accounts() }
        #expect(transport.requests.count == 1)
    }

    @Test func malformedJSONIsReported() async {
        await #expect(throws: MyQError.malformedResponse) {
            try await MyQClient(transport: FakeTransport([ok("<html>")]), tokens: FakeTokens()).accounts()
        }
    }

    @Test func transportFailureIsReported() async {
        await #expect(throws: MyQError.transport) {
            try await MyQClient(transport: FakeTransport([.failure(.transport)]), tokens: FakeTokens()).accounts()
        }
    }
}

@Suite struct MyQClientCommandTests {
    @Test(arguments: [(DoorAction.open, "open"), (.close, "close")])
    func sendsOnePutToTheEscapedCommandURL(_ action: DoorAction, _ path: String) async throws {
        let transport = FakeTransport([ok("", status: 202)])
        try await MyQClient(transport: transport, tokens: FakeTokens()).send(action, to: door)
        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.url.absoluteString == "https://account-devices-gdo.myq-cloud.com/api/v6.0/accounts/acc%2F1/door_openers/CG%201/\(path)")
        #expect(transport.requests.count == 1)
    }

    @Test(arguments: [200, 202, 204])
    func anySuccessIsAcceptedEvenWithAnEmptyBody(_ code: Int) async throws {
        try await MyQClient(transport: FakeTransport([ok("", status: code)]), tokens: FakeTokens()).send(.open, to: door)
    }

    @Test func everyUnprovenOutcomeIsUncertainAndSentOnce() async {
        let outcomes: [Result<HTTPResponse, MyQError>] = [status(401), status(403), status(429), status(500), status(302), .failure(.transport)]
        for outcome in outcomes {
            let transport = FakeTransport([outcome])
            let tokens = FakeTokens()
            await #expect(throws: CommandError.outcomeUnknown) { try await MyQClient(transport: transport, tokens: tokens).send(.close, to: door) }
            #expect(transport.requests.count == 1)
            #expect(tokens.rejections.isEmpty)
        }
    }

    @Test func tokenFailureBeforeSendingIsNotUncertain() async {
        final class NoTokens: AccessTokenProvider {
            func validAccessToken() async throws -> String { throw TokenError.signInRequired }
            func refreshAfterRejection(of token: String) async throws -> String { throw TokenError.signInRequired }
        }
        let transport = FakeTransport([])
        await #expect(throws: TokenError.signInRequired) { try await MyQClient(transport: transport, tokens: NoTokens()).send(.open, to: door) }
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct MyQTokenRefresherTests {
    @Test func postsTheRefreshGrantAsAForm() async throws {
        let transport = FakeTransport([ok(#"{"access_token":"a2","refresh_token":"r2","expires_in":1800}"#)])
        let response = try await MyQTokenRefresher(transport: transport).refresh(refreshToken: "r1 +&=")
        #expect(response == RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 1800))
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://partner-identity.myq-cloud.com/connect/token")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["Authorization"] == nil)
        let form = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=r1%20%2B%26%3D"))
        #expect(form.contains("client_id=\(MyQMetadata.oauthClientID)"))
    }

    @Test func missingReplacementTokenIsNil() async throws {
        let transport = FakeTransport([ok(#"{"access_token":"a2","expires_in":1800}"#)])
        #expect(try await MyQTokenRefresher(transport: transport).refresh(refreshToken: "r1").refreshToken == nil)
    }

    @Test(arguments: [400, 401])
    func invalidGrantIsRecognized(_ code: Int) async {
        let transport = FakeTransport([.success(HTTPResponse(status: code, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8)))])
        await #expect(throws: MyQError.invalidGrant) { try await MyQTokenRefresher(transport: transport).refresh(refreshToken: "r1") }
    }

    @Test func otherAuthErrorsAreUnauthorized() async {
        let transport = FakeTransport([.success(HTTPResponse(status: 400, headers: [:], body: Data(#"{"error":"invalid_client"}"#.utf8)))])
        await #expect(throws: MyQError.unauthorized) { try await MyQTokenRefresher(transport: transport).refresh(refreshToken: "r1") }
    }

    @Test(arguments: [#"{"refresh_token":"r"}"#, #"{"access_token":"","expires_in":1}"#, #"{"access_token":"a","expires_in":"1"}"#, #"{"access_token":"a","expires_in":0}"#, "nope"])
    func malformedTokenResponsesAreRejected(_ json: String) async {
        await #expect(throws: MyQError.malformedResponse) {
            try await MyQTokenRefresher(transport: FakeTransport([ok(json)])).refresh(refreshToken: "r1")
        }
    }
}

@Suite struct HostAllowlistTests {
    @Test(arguments: [
        "https://accounts.myq-cloud.com/x", "https://devices.myq-cloud.com/x", "https://account-devices-gdo.myq-cloud.com/x",
        "https://partner-identity.myq-cloud.com/connect/token",
    ])
    func allowsOnlyTheDocumentedHosts(_ raw: String) {
        #expect(MyQMetadata.isAllowed(URL(string: raw)!))
    }

    @Test(arguments: [
        "http://accounts.myq-cloud.com/x", "https://evil.example/x", "https://accounts.myq-cloud.com.evil.example/x",
        "https://accounts.myq-cloud.com:8443/x", "https://user@accounts.myq-cloud.com/x", "https://myq-cloud.com/x",
    ])
    func refusesEverythingElse(_ raw: String) {
        #expect(!MyQMetadata.isAllowed(URL(string: raw)!))
    }
}

@Suite struct TokenRejectionTests {
    @Test func rejectedTokenIsRefreshedEvenBeforeExpiry() async throws {
        let store = MemoryTokenStore(TokenRecord(accessToken: "a1", refreshToken: "r1", accessTokenExpiry: .distantFuture, generation: 1, lastRefresh: nil))
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        let coordinator = TokenCoordinator(store: store, lock: ImmediateLock(), refresher: refresher)
        #expect(try await coordinator.refreshAfterRejection(of: "a1") == "a2")
        #expect(refresher.calls == 1)
    }

    @Test func rejectionOfAnAlreadyReplacedTokenUsesTheNewOne() async throws {
        let store = MemoryTokenStore(TokenRecord(accessToken: "a2", refreshToken: "r2", accessTokenExpiry: .distantFuture, generation: 2, lastRefresh: nil))
        let refresher = FakeRefresher([])
        let coordinator = TokenCoordinator(store: store, lock: ImmediateLock(), refresher: refresher)
        #expect(try await coordinator.refreshAfterRejection(of: "a1") == "a2")
        #expect(refresher.calls == 0)
    }
}

@Suite struct DeviceCopyTests {
    @Test func stateCopyKeepsUnreadableSafetyFields() {
        let device = DoorDevice(
            identity: DoorIdentity(accountID: "a", serial: "d"), accountName: "Home", name: "Big", family: "garagedoor", state: .closed, online: true,
            unattendedOpenAllowed: true, unattendedCloseAllowed: true, vacationMode: nil, activeFaults: [], lastServerUpdate: nil, unreadableSafetyFields: ["in_vacation_mode"]
        )
        #expect(device.with(state: .opening).unreadableSafetyFields == ["in_vacation_mode"])
    }
}
