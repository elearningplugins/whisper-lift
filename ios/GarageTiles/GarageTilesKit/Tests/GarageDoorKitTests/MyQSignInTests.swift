import Foundation
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

@Suite struct PKCETests {
    // RFC 7636 appendix B test vector.
    @Test func challengeMatchesTheRFCVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifiersAreLongUnreservedAndUnique() {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let first = PKCE.generate()
        #expect((43...128).contains(first.verifier.count))
        #expect(first.verifier.unicodeScalars.allSatisfy(unreserved.contains))
        #expect(first.verifier != PKCE.generate().verifier)
        #expect(!first.challenge.contains("="))
    }
}

@Suite struct AuthorizationRequestTests {
    @Test func authorizationURLCarriesExactlyTheExpectedParameters() throws {
        let url = MyQSignIn.authorizationURL(pkce: PKCE(verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0)), state: "STATE-1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "partner-identity.myq-cloud.com")
        #expect(components.path == "/connect/authorize")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == [
            "client_id": MyQMetadata.oauthClientID,
            "redirect_uri": "com.myqops://android",
            "response_type": "code",
            "scope": MyQMetadata.oauthScope,
            "code_challenge": PKCE(verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0)).challenge,
            "code_challenge_method": "S256",
            "state": "STATE-1",
            "acr_values": "unified_flow:v1 brand:myq",
            "ui_locales": "en-US",
            "prompt": "login",
        ])
        #expect(MyQMetadata.isAllowed(url))
    }
}

@Suite struct CallbackParsingTests {
    @Test func exactCallbackYieldsTheCode() throws {
        #expect(try MyQSignIn.authorizationCode(from: URL(string: "com.myqops://android?code=abc123&state=S1")!, expectedState: "S1") == "abc123")
    }

    @Test func schemeComparisonIgnoresCase() throws {
        #expect(try MyQSignIn.authorizationCode(from: URL(string: "COM.MYQOPS://android?code=abc&state=S1")!, expectedState: "S1") == "abc")
    }

    @Test(arguments: [
        "com.myqops://android?code=abc&state=OTHER",
        "com.myqops://android?code=abc",
    ])
    func stateMismatchIsRejected(_ raw: String) {
        #expect(throws: SignInError.stateMismatch) { try MyQSignIn.authorizationCode(from: URL(string: raw)!, expectedState: "S1") }
    }

    @Test(arguments: [
        "com.myqops://androidx?code=abc&state=S1",
        "com.myqops://android.evil.example/?code=abc&state=S1",
        "com.myqops://android/extra?code=abc&state=S1",
        "com.myqops://user@android?code=abc&state=S1",
        "com.myqopsx://android?code=abc&state=S1",
        "https://partner-identity.myq-cloud.com/?code=abc&state=S1",
        "com.myqops://android?state=S1",
        "com.myqops://android?code=&state=S1",
    ])
    func malformedOrLookAlikeCallbacksAreRejected(_ raw: String) {
        #expect(throws: SignInError.invalidCallback) { try MyQSignIn.authorizationCode(from: URL(string: raw)!, expectedState: "S1") }
    }

    @Test func providerErrorIsReportedAsDenied() {
        #expect(throws: SignInError.denied) {
            try MyQSignIn.authorizationCode(from: URL(string: "com.myqops://android?error=access_denied&state=S1")!, expectedState: "S1")
        }
    }

    @Test func cancelAndRejectionUseTheDesignWording() {
        #expect(SignInError.cancelled.description == "Sign-in was cancelled. Nothing was saved. Try again whenever you\u{2019}re ready.")
        let rejected = "myQ didn\u{2019}t accept that sign-in. Check your email, password and code on myQ\u{2019}s page, then try again."
        #expect(SignInError.denied.description == rejected)
        #expect(SignInError.exchangeFailed.description == rejected)
    }

    @Test func errorsNeverContainTheCode() {
        for error in [SignInError.notConfigured, .cancelled, .denied, .invalidCallback, .stateMismatch, .appCheckFailed, .exchangeFailed, .malformedResponse] {
            #expect(!String(describing: error).contains("abc123"))
        }
    }
}

@Suite struct HostAllowlistSignInTests {
    @Test func appCheckHostIsAllowed() {
        #expect(MyQMetadata.isAllowed(URL(string: "https://firebaseappcheck.googleapis.com/v1/projects/x/apps/y:exchangeDebugToken")!))
    }

    @Test(arguments: ["https://www.googleapis.com/x", "https://firebaseappcheck.googleapis.com.evil.example/x", "http://firebaseappcheck.googleapis.com/x"])
    func otherGoogleHostsAreNot(_ raw: String) {
        #expect(!MyQMetadata.isAllowed(URL(string: raw)!))
    }
}

/** Returns a fixed callback URL, or throws, in place of the system sign-in sheet. */
struct FakeAuthenticator: WebAuthenticating {
    let result: Result<URL, SignInError>
    let seen: SeenURLs

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        seen.record(url, callbackScheme)
        return try result.get()
    }
}

final class SeenURLs: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    private(set) var schemes: [String] = []

    func record(_ url: URL, _ scheme: String) {
        lock.withLock {
            urls.append(url)
            schemes.append(scheme)
        }
    }
}

@Suite struct SignInFlowTests {
    private let verifier = String(repeating: "q", count: 50)

    private func flow(
        _ transport: FakeTransport, _ store: MemoryTokenStore, callback: Result<URL, SignInError>, seen: SeenURLs = SeenURLs(),
        configuration: MyQConfiguration? = try? MyQConfiguration(info: [MyQConfiguration.appCheckDebugTokenInfoKey: fakeDebugToken])
    ) -> MyQSignInFlow {
        MyQSignInFlow(
            transport: transport,
            tokens: TokenCoordinator(store: store, lock: ImmediateLock(), refresher: FakeRefresher([]), now: { now }),
            authenticator: FakeAuthenticator(result: callback, seen: seen),
            configuration: configuration,
            makePKCE: { PKCE(verifier: verifier) },
            makeState: { "S1" }
        )
    }

    private func ok(_ json: String) -> Result<HTTPResponse, MyQError> {
        .success(HTTPResponse(status: 200, headers: [:], body: Data(json.utf8)))
    }

    @Test func signInExchangesTheCodeAndSavesANewGeneration() async throws {
        let transport = FakeTransport([ok(#"{"token":"app-check-1","ttl":"3600s"}"#), ok(#"{"access_token":"a1","refresh_token":"r1","expires_in":1800}"#)])
        let store = MemoryTokenStore(TokenRecord(accessToken: "old", refreshToken: "old-r", accessTokenExpiry: .distantPast, generation: 4, lastRefresh: nil))
        let seen = SeenURLs()
        try await flow(transport, store, callback: .success(URL(string: "com.myqops://android?code=CODE-1&state=S1")!), seen: seen).signIn()

        #expect(seen.schemes == ["com.myqops"])
        #expect(seen.urls.first?.host == "partner-identity.myq-cloud.com")

        let appCheck = try #require(transport.requests.first)
        #expect(appCheck.method == "POST")
        #expect(appCheck.url.absoluteString == "https://firebaseappcheck.googleapis.com/v1/projects/\(MyQMetadata.firebaseProjectID)/apps/\(MyQMetadata.firebaseAppID):exchangeDebugToken?key=\(MyQMetadata.firebaseAPIKey)")
        #expect(appCheck.headers["X-Android-Package"] == MyQMetadata.androidPackage)
        #expect(appCheck.headers["X-Android-Cert"] == MyQMetadata.androidCertSHA1)
        let appCheckBody = try #require(try JSONSerialization.jsonObject(with: appCheck.body ?? Data()) as? [String: String])
        #expect(appCheckBody == ["debugToken": fakeDebugToken])

        let exchange = transport.requests[1]
        #expect(exchange.method == "POST")
        #expect(exchange.url.absoluteString == "https://partner-identity.myq-cloud.com/connect/token")
        #expect(exchange.headers["Firebase-AppCheck-Token"] == "app-check-1")
        let form = String(decoding: exchange.body ?? Data(), as: UTF8.self)
        for field in ["grant_type=authorization_code", "code=CODE-1", "code_verifier=\(verifier)", "redirect_uri=com.myqops%3A%2F%2Fandroid", "client_id=\(MyQMetadata.oauthClientID)"] {
            #expect(form.contains(field), "\(field)")
        }

        let saved = try #require(try store.read())
        #expect(saved == TokenRecord(accessToken: "a1", refreshToken: "r1", accessTokenExpiry: now.addingTimeInterval(1800), generation: 5, lastRefresh: now))
    }

    @Test func missingConfigurationStopsBeforeTheSheetOrAnyRequest() async throws {
        let transport = FakeTransport([])
        let store = MemoryTokenStore(nil)
        let seen = SeenURLs()
        await #expect(throws: SignInError.notConfigured) {
            try await flow(transport, store, callback: .success(URL(string: "com.myqops://android?code=C&state=S1")!), seen: seen, configuration: nil).signIn()
        }
        #expect(seen.urls.isEmpty)
        #expect(transport.requests.isEmpty)
        #expect(try store.read() == nil)
    }

    @Test func cancellingChangesNothing() async throws {
        let transport = FakeTransport([])
        let original = TokenRecord(accessToken: "a", refreshToken: "r", accessTokenExpiry: .distantFuture, generation: 2, lastRefresh: nil)
        let store = MemoryTokenStore(original)
        await #expect(throws: SignInError.cancelled) { try await flow(transport, store, callback: .failure(.cancelled)).signIn() }
        #expect(transport.requests.isEmpty)
        #expect(try store.read() == original)
    }

    @Test func forgedStateIsRejectedBeforeAnyExchange() async throws {
        let transport = FakeTransport([])
        let store = MemoryTokenStore(nil)
        await #expect(throws: SignInError.stateMismatch) {
            try await flow(transport, store, callback: .success(URL(string: "com.myqops://android?code=C&state=EVIL")!)).signIn()
        }
        #expect(transport.requests.isEmpty)
        #expect(try store.read() == nil)
    }

    @Test(arguments: [
        (#"{"nope":1}"#, 200, SignInError.appCheckFailed),
        ("", 403, SignInError.appCheckFailed),
    ])
    func appCheckFailuresSaveNothing(_ body: String, _ status: Int, _ expected: SignInError) async throws {
        let transport = FakeTransport([.success(HTTPResponse(status: status, headers: [:], body: Data(body.utf8)))])
        let store = MemoryTokenStore(nil)
        await #expect(throws: expected) {
            try await flow(transport, store, callback: .success(URL(string: "com.myqops://android?code=C&state=S1")!)).signIn()
        }
        #expect(try store.read() == nil)
    }

    @Test(arguments: [
        (#"{"error":"invalid_grant"}"#, 400, SignInError.exchangeFailed),
        ("", 500, SignInError.exchangeFailed),
        (#"{"access_token":"a1","expires_in":1800}"#, 200, SignInError.malformedResponse),
        (#"{"access_token":"","refresh_token":"r","expires_in":1800}"#, 200, SignInError.malformedResponse),
    ])
    func exchangeFailuresSaveNothing(_ body: String, _ status: Int, _ expected: SignInError) async throws {
        let transport = FakeTransport([ok(#"{"token":"t"}"#), .success(HTTPResponse(status: status, headers: [:], body: Data(body.utf8)))])
        let store = MemoryTokenStore(nil)
        await #expect(throws: expected) {
            try await flow(transport, store, callback: .success(URL(string: "com.myqops://android?code=C&state=S1")!)).signIn()
        }
        #expect(try store.read() == nil)
    }
}
