import Foundation

/** Checks a pasted refresh token before import (PLAN.md Phase 6); problems never repeat the pasted text. */
public enum TokenImport {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
        case empty
        case looksLikeAccessHeader
        case looksLikeJSON
        case containsWhitespace
        case unexpectedCharacters
        case tooShort
        case tooLong

        public var description: String {
            switch self {
            case .empty: "Paste the refresh token first."
            case .looksLikeAccessHeader: "That looks like an Authorization header. Paste only the refresh token."
            case .looksLikeJSON: "That looks like JSON. Paste only the refresh_token value."
            case .containsWhitespace: "The token has spaces in it. Copy it again as a single value."
            case .unexpectedCharacters: "The token has characters a refresh token never contains."
            case .tooShort: "That is too short to be a refresh token."
            case .tooLong: "That is too long to be a refresh token."
            }
        }

        public var errorDescription: String? { description }
    }

    static let allowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~+/=")
        return set
    }()

    /** Returns the trimmed token, or throws the first problem found. */
    public static func validate(_ pasted: String) throws -> String {
        let token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Problem.empty }
        if token.lowercased().hasPrefix("bearer ") { throw Problem.looksLikeAccessHeader }
        if token.hasPrefix("{") { throw Problem.looksLikeJSON }
        if token.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) { throw Problem.containsWhitespace }
        guard token.unicodeScalars.allSatisfy(allowed.contains) else { throw Problem.unexpectedCharacters }
        guard token.count >= 20 else { throw Problem.tooShort }
        guard token.count <= 4096 else { throw Problem.tooLong }
        return token
    }

    /** A record holding only the imported refresh token; its expired access token forces an immediate refresh, and its generation moves past any record it replaces. */
    public static func record(refreshToken: String, replacing existing: TokenRecord?) -> TokenRecord {
        TokenRecord(accessToken: "", refreshToken: refreshToken, accessTokenExpiry: .distantPast, generation: (existing?.generation ?? 0) + 1, lastRefresh: nil)
    }
}
