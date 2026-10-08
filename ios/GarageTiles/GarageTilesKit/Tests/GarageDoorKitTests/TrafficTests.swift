import Foundation
import Testing
@testable import GarageDoorKit

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Traffic-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct MeteredTransportTests {
    private let url = URL(string: "https://devices.myq-cloud.com/api/v6.2/Accounts/acct-SECRET-1/Devices")!

    @Test func recordsExactRequestAndResponseSizes() async throws {
        let log = TrafficLog(directory: tempDirectory())
        let inner = FakeTransport([.success(HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(repeating: 65, count: 1234)))])
        let transport = MeteredTransport(inner: inner, log: log, now: { now })
        let request = HTTPRequest(method: "GET", url: url, headers: ["Authorization": "Bearer tok-SECRET", "Accept": "application/json"], body: Data("abc".utf8))
        _ = try await transport.send(request)
        let entry = try #require(try log.read().last)
        #expect(entry.requestBytes == MeteredTransport.requestSize(request))
        #expect(entry.requestBytes == "GET /api/v6.2/Accounts/acct-SECRET-1/Devices HTTP/1.1\r\n".utf8.count + "Host: devices.myq-cloud.com\r\n".utf8.count
            + "Authorization: Bearer tok-SECRET\r\n".utf8.count + "Accept: application/json\r\n".utf8.count + "\r\n".utf8.count + 3)
        #expect(entry.responseBytes == "HTTP/1.1 200 OK\r\n".utf8.count + "Content-Type: application/json\r\n".utf8.count + 2 + 1234)
        #expect(entry.status == 200)
        #expect(entry.method == "GET")
        #expect(entry.host == "devices.myq-cloud.com")
        #expect(entry.date == now)
    }

    @Test func pathsAreRecordedWithoutAccountIDsOrSerials() async throws {
        let log = TrafficLog(directory: tempDirectory())
        let transport = MeteredTransport(inner: FakeTransport([.success(HTTPResponse(status: 202, headers: [:], body: Data()))]), log: log, now: { now })
        let put = URL(string: "https://account-devices-gdo.myq-cloud.com/api/v6.0/accounts/acct-SECRET-1/door_openers/SERIAL-SECRET/open")!
        _ = try await transport.send(HTTPRequest(method: "PUT", url: put, headers: ["Authorization": "Bearer tok-SECRET"]))
        let entry = try #require(try log.read().last)
        #expect(entry.path == "/api/v6.0/accounts/{account}/door_openers/{serial}/open")
        let stored = String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self)
        #expect(!stored.contains("SECRET"))
    }

    @Test(arguments: [
        ("/api/v6.2/Accounts/a1/Devices", "/api/v6.2/Accounts/{account}/Devices"),
        ("/api/v6.0/accounts", "/api/v6.0/accounts"),
        ("/connect/token", "/connect/token"),
        ("/api/v6.0/accounts/a1/door_openers/s1/close", "/api/v6.0/accounts/{account}/door_openers/{serial}/close"),
    ])
    func pathTemplates(_ raw: String, _ expected: String) {
        #expect(MeteredTransport.template(raw) == expected)
    }

    // URL.path percent-decodes, so an encoded slash inside an ID used to split it and leak the second half.
    @Test func encodedSeparatorsInsideIdentifiersNeverLeak() async throws {
        let log = TrafficLog(directory: tempDirectory())
        let transport = MeteredTransport(inner: FakeTransport([.success(HTTPResponse(status: 202, headers: [:], body: Data()))]), log: log, now: { now })
        let put = URL(string: "https://account-devices-gdo.myq-cloud.com/api/v6.0/accounts/acc%2FSECRET-A/door_openers/ser%2FSECRET-B%3Fx/open")!
        _ = try await transport.send(HTTPRequest(method: "PUT", url: put, headers: [:]))
        let entry = try #require(try log.read().last)
        #expect(entry.path == "/api/v6.0/accounts/{account}/door_openers/{serial}/open")
        #expect(!String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self).contains("SECRET"))
    }

    @Test func emptyResponsesStillCountTheStatusLineAndHeaders() {
        let size = MeteredTransport.responseSize(HTTPResponse(status: 202, headers: [:], body: Data()))
        #expect(size == "HTTP/1.1 202 Accepted\r\n".utf8.count + "\r\n".utf8.count)
    }

    @Test func responseSizeIncludesStatusLineHeadersBlankLineAndBody() {
        let size = MeteredTransport.responseSize(HTTPResponse(status: 200, headers: ["A": "b"], body: Data(repeating: 1, count: 10)))
        #expect(size == "HTTP/1.1 200 OK\r\n".utf8.count + "A: b\r\n".utf8.count + 2 + 10)
    }

    @Test func summaryIsLabelledAsAnEstimate() {
        #expect(TrafficSummary(requests: 2, requestBytes: 2900, responseBytes: 2600).text == "2 requests, about 2.9 KB sent, about 2.6 KB received")
    }

    @Test func failuresAreLoggedWithoutAStatusAndRethrown() async throws {
        let log = TrafficLog(directory: tempDirectory())
        let transport = MeteredTransport(inner: FakeTransport([.failure(.transport)]), log: log, now: { now })
        await #expect(throws: MyQError.transport) { try await transport.send(HTTPRequest(method: "GET", url: url, headers: [:])) }
        let entry = try #require(try log.read().last)
        #expect(entry.status == nil)
        #expect(entry.responseBytes == 0)
    }

    @Test func logKeepsOnlyTheMostRecentEntries() throws {
        let log = TrafficLog(directory: tempDirectory(), capacity: 5)
        for index in 0..<8 {
            try log.append(TrafficEntry(date: now.addingTimeInterval(Double(index)), method: "GET", host: "h", path: "/\(index)", status: 200, requestBytes: index, responseBytes: 0))
        }
        #expect(try log.read().map(\.path) == ["/3", "/4", "/5", "/6", "/7"])
    }

    @Test func summarizesARecentBurstOfRequests() {
        let entries = [
            TrafficEntry(date: now.addingTimeInterval(-600), method: "GET", host: "h", path: "/old", status: 200, requestBytes: 999, responseBytes: 999),
            TrafficEntry(date: now, method: "GET", host: "h", path: "/a", status: 200, requestBytes: 1500, responseBytes: 2500),
            TrafficEntry(date: now.addingTimeInterval(2), method: "PUT", host: "h", path: "/b", status: 202, requestBytes: 1400, responseBytes: 100),
        ]
        let summary = TrafficLog.lastBurst(entries, gap: 60)
        #expect(summary == TrafficSummary(requests: 2, requestBytes: 2900, responseBytes: 2600))
        #expect(summary?.text == "2 requests, about 2.9 KB sent, about 2.6 KB received")
        #expect(TrafficLog.lastBurst([], gap: 60) == nil)
    }
}

@Suite struct CommandProfileTests {
    private let big = CatalogDoor(identity: DoorIdentity(accountID: "account-1", serial: "door-2"), accountName: "Home", name: "Two Car Garage")

    private func devices(_ state: String) -> Result<HTTPResponse, MyQError> {
        .success(HTTPResponse(status: 200, headers: [:], body: Data("""
        {"items":[{"serial_number":"door-2","name":"Two Car Garage","device_family":"garagedoor","state":{"door_state":"\(state)","online":true,"is_unattended_open_allowed":true,"is_unattended_close_allowed":true}}]}
        """.utf8)))
    }

    private func environment(_ transport: FakeTransport, profile: CommandProfile) throws -> GarageEnvironment {
        let keychain = FakeKeychain()
        keychain.stored = try JSONEncoder().encode(TokenRecord(accessToken: "a", refreshToken: "r", accessTokenExpiry: .distantFuture, generation: 1, lastRefresh: nil))
        let env = GarageEnvironment(dataDirectory: tempDirectory(), keychainGroup: "T.g", transport: transport, keychain: keychain, profile: profile, now: { now }, sleep: { _ in })
        try env.catalogStore.write(DoorCatalog(doors: [big]))
        return env
    }

    @Test func siriSendsOneReadAndOneCommandThenAnswers() async throws {
        let transport = FakeTransport([devices("closed"), .success(HTTPResponse(status: 202, headers: [:], body: Data()))])
        let env = try environment(transport, profile: .siri)
        let result = await env.perform(.open, on: big.identity)
        #expect(transport.requests.map(\.method) == ["GET", "PUT"])
        #expect(result.dialog == "Two Car Garage is opening.")
    }

    // The app screen now returns as soon as myQ accepts, so a tap never blocks the screen; GarageEnvironment.followUp confirms the movement afterwards.
    @Test func appScreenReturnsAsSoonAsMyQAccepts() async throws {
        let transport = FakeTransport([devices("closed"), .success(HTTPResponse(status: 202, headers: [:], body: Data()))])
        let env = try environment(transport, profile: .interactive)
        let result = await env.perform(.open, on: big.identity)
        #expect(transport.requests.map(\.method) == ["GET", "PUT"])
        #expect(result.dialog == "Two Car Garage is opening.")
    }

    @Test func profilesHaveTheDocumentedReadCounts() {
        #expect(CommandProfile.siri.followUpReads == 0)
        #expect(CommandProfile.interactive.followUpReads == 0)
    }

    @Test func everyRequestIsMetered() async throws {
        let transport = FakeTransport([devices("closed"), .success(HTTPResponse(status: 202, headers: [:], body: Data()))])
        let env = try environment(transport, profile: .siri)
        _ = await env.perform(.open, on: big.identity)
        #expect(try env.trafficLog.read().map(\.method) == ["GET", "PUT"])
    }
}
