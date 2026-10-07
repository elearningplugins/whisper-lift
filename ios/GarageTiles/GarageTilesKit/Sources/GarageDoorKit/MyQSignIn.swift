import CryptoKit
import Foundation

/** A PKCE verifier and its S256 challenge, so an intercepted authorization code is useless without the verifier (RFC 7636). */
public struct PKCE: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /** 32 random bytes as base64url, a 43-character verifier from the unreserved set. */
    public static func generate() -> PKCE {
        PKCE(verifier: randomToken())
    }

    public static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/** Why sign-in stopped; none of these carry a code, token or password. */
public enum SignInError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConfigured
    case cancelled
    case denied
    case invalidCallback
    case stateMismatch
    case appCheckFailed
    case exchangeFailed
    case malformedResponse

    public var description: String {
        switch self {
        case .notConfigured: "Sign-in is not set up in this build. Add the App Check debug token to config/MyQ.local.xcconfig and rebuild."
        case .cancelled: "Sign-in was cancelled. Nothing was saved. Try again whenever you\u{2019}re ready."
        case .denied, .exchangeFailed: "myQ didn\u{2019}t accept that sign-in. Check your email, password and code on myQ\u{2019}s page, then try again."
        case .invalidCallback: "myQ returned an unexpected sign-in response. Try again."
        case .stateMismatch: "The sign-in response did not match this request, so it was ignored. Try again."
        case .appCheckFailed: "myQ's app verification step failed. Try again later."
        case .malformedResponse: "myQ returned an incomplete sign-in response. Try again."
        }
    }
}

/** Shows myQ's own sign-in page and returns the callback URL; the app implements it with ASWebAuthenticationSession. */
public protocol WebAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

public enum MyQSignIn {
    public static let callbackScheme = "com.myqops"
    static let callbackHost = "android"

    public static func authorizationURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = MyQMetadata.identityHost
        components.path = "/connect/authorize"
        components.queryItems = [
            URLQueryItem(name: "acr_values", value: "unified_flow:v1 brand:myq"),
            URLQueryItem(name: "client_id", value: MyQMetadata.oauthClientID),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "ui_locales", value: "en-US"),
            URLQueryItem(name: "redirect_uri", value: MyQMetadata.oauthRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: MyQMetadata.oauthScope),
            URLQueryItem(name: "prompt", value: "login"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /** Accepts only the exact com.myqops://android callback carrying this request's state, never a prefix or look-alike. */
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard
            let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == callbackScheme,
            components.user == nil, components.password == nil, components.port == nil,
            components.host == callbackHost,
            components.path.isEmpty
        else { throw SignInError.invalidCallback }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        guard items["state"] == expectedState else { throw SignInError.stateMismatch }
        if items["error"] != nil { throw SignInError.denied }
        guard let code = items["code"], !code.isEmpty else { throw SignInError.invalidCallback }
        return code
    }
}

/** The whole in-app sign-in: myQ's page, the code, App Check, the token exchange, and saving the session under the refresh lock. */
public struct MyQSignInFlow: Sendable {
    let transport: any HTTPTransport
    let tokens: TokenCoordinator
    let authenticator: any WebAuthenticating
    let configuration: MyQConfiguration?
    let makePKCE: @Sendable () -> PKCE
    let makeState: @Sendable () -> String

    public init(
        transport: any HTTPTransport,
        tokens: TokenCoordinator,
        authenticator: any WebAuthenticating,
        configuration: MyQConfiguration?,
        makePKCE: @escaping @Sendable () -> PKCE = { PKCE.generate() },
        makeState: @escaping @Sendable () -> String = { PKCE.randomToken() }
    ) {
        self.transport = transport
        self.tokens = tokens
        self.authenticator = authenticator
        self.configuration = configuration
        self.makePKCE = makePKCE
        self.makeState = makeState
    }

    public func signIn() async throws {
        guard let configuration else { throw SignInError.notConfigured }
        let pkce = makePKCE()
        let state = makeState()
        let callback = try await authenticator.authenticate(url: MyQSignIn.authorizationURL(pkce: pkce, state: state), callbackScheme: MyQSignIn.callbackScheme)
        let code = try MyQSignIn.authorizationCode(from: callback, expectedState: state)
        let appCheck = try await appCheckToken(debugToken: configuration.appCheckDebugToken)
        let response = try await exchange(code: code, verifier: pkce.verifier, appCheck: appCheck)
        try await tokens.adoptSession(response)
    }

    private func appCheckToken(debugToken: String) async throws -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = MyQMetadata.appCheckHost
        components.percentEncodedPath = "/v1/projects/\(MyQMetadata.firebaseProjectID)/apps/\(MyQMetadata.firebaseAppID):exchangeDebugToken"
        components.queryItems = [URLQueryItem(name: "key", value: MyQMetadata.firebaseAPIKey)]
        let body = try JSONSerialization.data(withJSONObject: ["debugToken": debugToken])
        let headers = ["Content-Type": "application/json", "X-Android-Package": MyQMetadata.androidPackage, "X-Android-Cert": MyQMetadata.androidCertSHA1]
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: "POST", url: components.url!, headers: headers, body: body))
        } catch {
            throw SignInError.appCheckFailed
        }
        guard (200..<300).contains(response.status),
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty
        else { throw SignInError.appCheckFailed }
        return token
    }

    private func exchange(code: String, verifier: String, appCheck: String) async throws -> RefreshResponse {
        let form = [
            ("client_id", MyQMetadata.oauthClientID),
            ("scope", MyQMetadata.oauthScope),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", MyQMetadata.oauthRedirectURI),
            ("code_verifier", verifier),
        ].map { "\(MyQMetadata.escape($0.0))=\(MyQMetadata.escape($0.1))" }.joined(separator: "&")
        let headers = MyQMetadata.commonHeaders().merging(["Content-Type": "application/x-www-form-urlencoded", "Firebase-AppCheck-Token": appCheck]) { _, new in new }
        let response: HTTPResponse
        do {
            response = try await transport.send(
                HTTPRequest(method: "POST", url: MyQMetadata.url(host: MyQMetadata.identityHost, path: "/connect/token"), headers: headers, body: Data(form.utf8))
            )
        } catch {
            throw SignInError.exchangeFailed
        }
        guard (200..<300).contains(response.status) else { throw SignInError.exchangeFailed }
        guard
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let access = object["access_token"] as? String, !access.isEmpty,
            let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
            let lifetime = object["expires_in"] as? NSNumber, CFGetTypeID(lifetime) != CFBooleanGetTypeID(), lifetime.doubleValue > 0
        else { throw SignInError.malformedResponse }
        return RefreshResponse(accessToken: access, refreshToken: refresh, expiresIn: lifetime.doubleValue)
    }
}
