#if canImport(UIKit)
import AuthenticationServices
import GarageDoorKit
import UIKit

/** Shows myQ's own sign-in page in an ephemeral system browser sheet, so this app never sees the password or MFA code. */
@MainActor
final class WebSignIn: NSObject, WebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await start(url: url, callbackScheme: callbackScheme)
    }

    private func start(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            // The handler only resumes the continuation, so it is safe on whichever thread the system calls it.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SignInError.cancelled)
                } else {
                    continuation.resume(throwing: SignInError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SignInError.invalidCallback)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first { return window }
            // The sheet starts from a tap in a visible window, so a scene always exists here.
            guard let scene = scenes.first else { preconditionFailure("Sign-in started with no window scene") }
            return ASPresentationAnchor(windowScene: scene)
        }
    }
}
#endif
