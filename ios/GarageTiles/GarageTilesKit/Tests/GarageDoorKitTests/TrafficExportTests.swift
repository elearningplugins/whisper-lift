import Foundation
import PropertyTestSupport
import Testing
@testable import GarageDoorKit

private let exportedAt = Date(timeIntervalSince1970: 1_790_000_100)

private func entry(_ path: String, host: String = "devices.myq-cloud.com", method: String = "GET", status: Int? = 200, sent: Int = 100, received: Int = 200, at seconds: TimeInterval = 0) -> TrafficEntry {
    TrafficEntry(
        date: Date(timeIntervalSince1970: 1_790_000_000 + seconds), method: method, host: host, path: path, status: status,
        requestBytes: sent, responseBytes: received
    )
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct TrafficExportTests {
    @Test func exportListsEveryRequestWithItsAPISizeAndStatus() throws {
        let entries = [
            entry("/api/v6.2/Accounts/{account}/Devices", sent: 310, received: 1890),
            entry("/api/v6.0/accounts/{account}/door_openers/{serial}/open", host: "account-devices-gdo.myq-cloud.com", method: "PUT", status: 202, sent: 420, received: 60, at: 1.5),
        ]
        let json = try object(TrafficExport.json(entries, exportedAt: exportedAt, appVersion: "0.0.1 (1)"))
        #expect(json["format"] as? String == "whisper-lift-request-log")
        #expect(json["formatVersion"] as? Int == 1)
        #expect(json["exportedAt"] as? String == "2026-09-21T14:15:00Z")
        #expect(json["appVersion"] as? String == "0.0.1 (1)")
        #expect((json["sizeNote"] as? String)?.isEmpty == false)
        let totals = try #require(json["totals"] as? [String: Int])
        #expect(totals == ["requests": 2, "failedRequests": 0, "requestBytes": 730, "responseBytes": 1950, "totalBytes": 2680])
        let requests = try #require(json["requests"] as? [[String: Any]])
        #expect(requests.count == 2)
        #expect(requests[0]["time"] as? String == "2026-09-21T14:13:20Z")
        #expect(requests[0]["method"] as? String == "GET")
        #expect(requests[0]["host"] as? String == "devices.myq-cloud.com")
        #expect(requests[0]["endpoint"] as? String == "/api/v6.2/Accounts/{account}/Devices")
        #expect(requests[0]["url"] as? String == "https://devices.myq-cloud.com/api/v6.2/Accounts/{account}/Devices")
        #expect(requests[0]["status"] as? Int == 200)
        #expect(requests[0]["requestBytes"] as? Int == 310)
        #expect(requests[0]["responseBytes"] as? Int == 1890)
        #expect(requests[1]["method"] as? String == "PUT")
        #expect(requests[1]["endpoint"] as? String == "/api/v6.0/accounts/{account}/door_openers/{serial}/open")
        #expect(requests[1]["time"] as? String == "2026-09-21T14:13:21.500Z")
    }

    @Test func failedRequestsKeepANullStatusAndAreCounted() throws {
        let entries = [entry("/connect/token", host: "partner-identity.myq-cloud.com", method: "POST", status: nil, received: 0), entry("/api/v6.0/accounts", host: "accounts.myq-cloud.com", status: 401)]
        let json = try object(TrafficExport.json(entries, exportedAt: exportedAt, appVersion: "1"))
        let requests = try #require(json["requests"] as? [[String: Any]])
        #expect(requests[0]["status"] is NSNull)
        #expect((json["totals"] as? [String: Int])?["failedRequests"] == 2)
    }

    @Test func anEmptyLogExportsValidJSON() throws {
        let json = try object(TrafficExport.json([], exportedAt: exportedAt, appVersion: "1"))
        #expect((json["requests"] as? [Any])?.isEmpty == true)
        #expect(json["totals"] as? [String: Int] == ["requests": 0, "failedRequests": 0, "requestBytes": 0, "responseBytes": 0, "totalBytes": 0])
    }

    @Test func outputIsStableAndReadable() throws {
        let entries = [entry("/api/v6.0/accounts", host: "accounts.myq-cloud.com")]
        let first = try TrafficExport.json(entries, exportedAt: exportedAt, appVersion: "1")
        #expect(first == (try TrafficExport.json(entries, exportedAt: exportedAt, appVersion: "1")))
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("\n"), "pretty-printed for reading")
        #expect(text.contains("https://accounts.myq-cloud.com/api"), "slashes are not escaped")
    }

    @Test(arguments: [(0.6, "2026-09-21T14:13:20.600Z"), (0.001, "2026-09-21T14:13:20.001Z"), (0.999, "2026-09-21T14:13:20.999Z"), (59.9996, "2026-09-21T14:14:20Z"), (0, "2026-09-21T14:13:20Z")])
    func timestampsKeepExactMilliseconds(_ offset: TimeInterval, _ expected: String) {
        #expect(TrafficExport.timestamp(Date(timeIntervalSince1970: 1_790_000_000 + offset)) == expected)
    }

    @Test func fileNameCarriesTheExportTimeInUTC() {
        #expect(TrafficExport.fileName(exportedAt: exportedAt) == "whisper-lift-requests-20260921-141500Z.json")
    }

    // Entries are stored as templates already; the export templates again so an identifier can never leave the device, whatever wrote the log.
    @Test func identifiersNeverAppearInTheExport() throws {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_%.")
        try forAll(iterations: 300, { rng -> (String, String) in
            let id = { (rng: inout SplitMix64) in String((0..<Int.random(in: 6...24, using: &rng)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }) }
            return ("ACCT" + id(&rng), "SER" + id(&rng))
        }) { account, serial in
            let raw = [
                entry("/api/v6.2/Accounts/\(account)/Devices"),
                entry("/api/v6.0/accounts/\(account)/door_openers/\(serial)/close", host: "account-devices-gdo.myq-cloud.com", method: "PUT"),
            ]
            let text = String(decoding: try TrafficExport.json(raw, exportedAt: exportedAt, appVersion: "1"), as: UTF8.self)
            return !text.contains(account) && !text.contains(serial)
        }
    }

    @Test func theLogKeepsEnoughHistoryToExport() {
        #expect(TrafficLog(directory: FileManager.default.temporaryDirectory).capacity == 500)
    }
}
