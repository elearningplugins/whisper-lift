import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

private let realistic = String(repeating: "A1b2-C3d4_E5f6.", count: 4)

@Suite struct TokenImportTests {
    @Test func trimsSurroundingWhitespaceAndNewlines() throws {
        #expect(try TokenImport.validate("  \n\(realistic)\t\r\n") == realistic)
    }

    @Test(arguments: [
        ("", TokenImport.Problem.empty),
        ("   \n", .empty),
        ("short", .tooShort),
        (String(repeating: "a", count: 4097), .tooLong),
        ("Bearer \(realistic)", .looksLikeAccessHeader),
        ("bearer \(realistic)", .looksLikeAccessHeader),
        (#"{"refresh_token":"\#(realistic)"}"#, .looksLikeJSON),
        ("abc def ghi jkl mno pqr stu vwx", .containsWhitespace),
        ("\(realistic)é", .unexpectedCharacters),
        ("\(realistic)\u{0}", .unexpectedCharacters),
        ("driver@example.com-and-more-text", .unexpectedCharacters),
    ])
    func rejectsWhatCannotBeARefreshToken(_ pasted: String, _ problem: TokenImport.Problem) {
        #expect(throws: problem) { try TokenImport.validate(pasted) }
    }

    @Test func boundariesAreTwentyAndFourThousandNinetySixCharacters() throws {
        #expect(throws: TokenImport.Problem.tooShort) { try TokenImport.validate(String(repeating: "a", count: 19)) }
        #expect(try TokenImport.validate(String(repeating: "a", count: 20)).count == 20)
        #expect(try TokenImport.validate(String(repeating: "a", count: 4096)).count == 4096)
    }

    @Test func problemsNeverEchoThePastedText() {
        let pasted = "Bearer SECRET-\(realistic)"
        do {
            _ = try TokenImport.validate(pasted)
            Issue.record("expected a problem")
        } catch {
            #expect(!String(describing: error).contains("SECRET"))
            #expect(!error.localizedDescription.contains("SECRET"))
        }
    }

    @Test func importedRecordForcesAnImmediateRefreshAndAdvancesTheGeneration() async throws {
        let imported = TokenImport.record(refreshToken: realistic, replacing: TokenRecord(accessToken: "a", refreshToken: "old", accessTokenExpiry: .distantFuture, generation: 7, lastRefresh: nil))
        #expect(imported.generation == 8)
        #expect(imported.accessToken.isEmpty)
        #expect(imported.accessTokenExpiry == .distantPast)
        let store = MemoryTokenStore(imported)
        let refresher = FakeRefresher([.success(RefreshResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 3600))])
        #expect(try await TokenCoordinator(store: store, lock: ImmediateLock(), refresher: refresher).validAccessToken() == "a2")
        #expect(refresher.received == [realistic])
    }

    @Test func firstImportStartsAtGenerationOne() {
        #expect(TokenImport.record(refreshToken: realistic, replacing: nil).generation == 1)
    }

    @Test func acceptedTokensAreAlwaysTrimmedPrintableAndBounded() {
        let pieces = ["a", "Z", "0", "-", "_", ".", "~", "+", "/", "=", " ", "\n", "é", "{", "Bearer ", realistic]
        forAll(iterations: 1000, { rng in Gen.string(&rng, from: pieces, maxPieces: 12) }) { pasted in
            guard let token = try? TokenImport.validate(pasted) else { return true }
            return (20...4096).contains(token.count)
                && token.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic || CharacterSet(charactersIn: "0123456789-._~+/=").contains($0) }
                && token == pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
