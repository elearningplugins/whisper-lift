import Foundation
import Testing
@testable import GarageDoorKit

/** Answers every request in-process, so these tests never touch the network. */
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var fails = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply()
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var seenBodies: [Data] = []

    static func reset(_ next: Reply) {
        lock.withLock {
            reply = next
            seen = []
            seenBodies = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { seen } }
    static var bodies: [Data] { lock.withLock { seenBodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let current = Self.lock.withLock {
            Self.seen.append(request)
            Self.seenBodies.append(body)
            return Self.reply
        }
        if current.fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: current.status, httpVersion: "HTTP/1.1", headerFields: current.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized) struct URLSessionTransportTests {
    private func transport(maxBodyBytes: Int = 1024) -> URLSessionTransport {
        let configuration = URLSessionTransport.defaultConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(configuration: configuration, maxBodyBytes: maxBodyBytes)
    }

    private let accounts = URL(string: "https://accounts.myq-cloud.com/api/v6.0/accounts")!

    @Test func passesMethodHeadersAndBodyThrough() async throws {
        StubProtocol.reset(.init(status: 202, headers: ["Retry-After": "5"], body: Data("ok".utf8)))
        let response = try await transport().send(HTTPRequest(method: "POST", url: accounts, headers: ["X-Test": "1"], body: Data("form".utf8)))
        #expect(response.status == 202)
        #expect(response.body == Data("ok".utf8))
        #expect(response.header("retry-after") == "5")
        let request = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Test") == "1")
        #expect(StubProtocol.bodies.first == Data("form".utf8))
    }

    @Test func refusesUnapprovedURLsBeforeAnyRequest() async {
        StubProtocol.reset(.init())
        for raw in ["https://evil.example/x", "http://accounts.myq-cloud.com/x", "https://accounts.myq-cloud.com:8443/x"] {
            await #expect(throws: MyQError.transport) { try await transport().send(HTTPRequest(method: "GET", url: URL(string: raw)!, headers: [:])) }
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func bodyAtTheLimitIsReturned() async throws {
        StubProtocol.reset(.init(body: Data(repeating: 65, count: 1024)))
        #expect(try await transport().send(HTTPRequest(method: "GET", url: accounts, headers: [:])).body.count == 1024)
    }

    @Test func bodyOverTheLimitIsRejected() async {
        StubProtocol.reset(.init(body: Data(repeating: 65, count: 1025)))
        await #expect(throws: MyQError.malformedResponse) { try await transport().send(HTTPRequest(method: "GET", url: accounts, headers: [:])) }
    }

    @Test func connectionFailureIsTransport() async {
        StubProtocol.reset(.init(fails: true))
        await #expect(throws: MyQError.transport) { try await transport().send(HTTPRequest(method: "GET", url: accounts, headers: [:])) }
    }

    // A missing completion call would hang this test, so it is time-limited to fail instead.
    @Test(.timeLimit(.minutes(1))) func redirectsAreNeverFollowed() async {
        let delegate = NoRedirects()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: accounts)
        let redirect = HTTPURLResponse(url: accounts, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example/"])!
        let followed: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://evil.example/")!)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(followed == nil)
    }

    @Test func defaultConfigurationIsPrivateAndBounded() {
        let configuration = URLSessionTransport.defaultConfiguration()
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
        #expect(configuration.waitsForConnectivity == false)
        #expect(URLSessionTransport().maxBodyBytes == 1024 * 1024)
    }
}
