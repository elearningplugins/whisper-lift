import Foundation

public protocol RemovableTokenStore: TokenStore {
    func remove() throws
}

extension KeychainTokenStore: RemovableTokenStore {}

/** Imports a pasted phone refresh token and proves it with one refresh; a rejected token is rolled back (PLAN.md Phase 6). */
public struct SessionImporter: Sendable {
    public enum ImportError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalid(TokenImport.Problem)
        case rejected
        case unverified

        public var description: String {
            switch self {
            case .invalid(let problem): problem.description
            case .rejected: "myQ rejected that token. Use Sign in with myQ instead."
            case .unverified: "The token is saved, but myQ couldn't be reached to check it. Try Refresh when you're online."
            }
        }
    }

    let store: any RemovableTokenStore
    let tokens: TokenCoordinator

    public init(store: any RemovableTokenStore, tokens: TokenCoordinator) {
        self.store = store
        self.tokens = tokens
    }

    public func importToken(_ pasted: String) async throws {
        let token: String
        do {
            token = try TokenImport.validate(pasted)
        } catch let problem as TokenImport.Problem {
            throw ImportError.invalid(problem)
        }
        // One locked, generation-aware transaction, so a concurrent refresh by the app or widget can neither overwrite nor be overwritten.
        switch try await tokens.importRefreshToken(token) {
        case .verified: return
        case .rejected: throw ImportError.rejected
        case .unverified: throw ImportError.unverified
        }
    }
}
