import Foundation

/** One myQ request as sent and received; the path is a template, so no account ID, serial or token is ever stored. */
public struct TrafficEntry: Codable, Equatable, Sendable {
    public let date: Date
    public let method: String
    public let host: String
    public let path: String
    public let status: Int?
    public let requestBytes: Int
    public let responseBytes: Int
}

public struct TrafficSummary: Equatable, Sendable {
    public let requests: Int
    public let requestBytes: Int
    public let responseBytes: Int

    public var text: String {
        "\(requests) request\(requests == 1 ? "" : "s"), about \(Self.kilobytes(requestBytes)) sent, about \(Self.kilobytes(responseBytes)) received"
    }

    static func kilobytes(_ bytes: Int) -> String {
        String(format: "%.1f KB", Double(bytes) / 1000)
    }
}

/** The last requests in the App Group, shared by the app and Siri; a lost entry under a concurrent write only affects diagnostics. */
public struct TrafficLog: Sendable {
    public let directory: URL
    public let capacity: Int

    public init(directory: URL, capacity: Int = 500) {
        self.directory = directory
        self.capacity = capacity
    }

    var fileURL: URL { directory.appendingPathComponent("traffic-log.json", isDirectory: false) }

    public func read() throws -> [TrafficEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([TrafficEntry].self, from: data)
    }

    public func append(_ entry: TrafficEntry) throws {
        let entries = (((try? read()) ?? []) + [entry]).suffix(capacity)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The log reveals when doors were used, so it gets the same file protection as the other door data.
        #if os(iOS)
        try JSONEncoder().encode(Array(entries)).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(Array(entries)).write(to: fileURL, options: [.atomic])
        #endif
    }

    /** Deletes the log; a log that was never written counts as deleted. */
    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /** Totals the most recent run of requests, each within `gap` seconds of the next, which is one command or refresh. */
    public static func lastBurst(_ entries: [TrafficEntry], gap: TimeInterval = 60) -> TrafficSummary? {
        guard var previous = entries.last else { return nil }
        var burst = [previous]
        for entry in entries.dropLast().reversed() {
            guard previous.date.timeIntervalSince(entry.date) <= gap else { break }
            burst.append(entry)
            previous = entry
        }
        return TrafficSummary(requests: burst.count, requestBytes: burst.map(\.requestBytes).reduce(0, +), responseBytes: burst.map(\.responseBytes).reduce(0, +))
    }
}

/** Wraps a transport and logs each request's estimated size: the HTTP/1.1 messages as the app builds them, excluding headers URLSession adds and any compression. */
public struct MeteredTransport: HTTPTransport {
    let inner: any HTTPTransport
    let log: TrafficLog
    let now: @Sendable () -> Date

    public init(inner: any HTTPTransport, log: TrafficLog, now: @escaping @Sendable () -> Date = { Date() }) {
        self.inner = inner
        self.log = log
        self.now = now
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let sentAt = now()
        do {
            let response = try await inner.send(request)
            record(request, at: sentAt, status: response.status, responseBytes: Self.responseSize(response))
            return response
        } catch {
            record(request, at: sentAt, status: nil, responseBytes: 0)
            throw error
        }
    }

    private func record(_ request: HTTPRequest, at date: Date, status: Int?, responseBytes: Int) {
        let entry = TrafficEntry(
            date: date, method: request.method, host: request.url.host ?? "", path: Self.template(Self.encodedPath(request.url)), status: status,
            requestBytes: Self.requestSize(request), responseBytes: responseBytes
        )
        try? log.append(entry)
    }

    static func requestSize(_ request: HTTPRequest) -> Int {
        var target = encodedPath(request.url)
        if let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery { target += "?" + query }
        let lines = ["\(request.method) \(target) HTTP/1.1", "Host: \(request.url.host ?? "")"] + request.headers.map { "\($0.key): \($0.value)" }
        return lines.map { $0.utf8.count + 2 }.reduce(0, +) + 2 + (request.body?.count ?? 0)
    }

    static func responseSize(_ response: HTTPResponse) -> Int {
        let statusLine = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))".utf8.count + 2
        return statusLine + response.headers.map { "\($0.key): \($0.value)".utf8.count + 2 }.reduce(0, +) + 2 + response.body.count
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    /** The path still percent-encoded, so an encoded slash inside an account ID or serial stays inside its segment. */
    static func encodedPath(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    }

    /** Replaces the account and serial segments with placeholders. */
    static func template(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for index in parts.indices.dropLast() {
            switch parts[index].lowercased() {
            case "accounts": parts[index + 1] = "{account}"
            case "door_openers": parts[index + 1] = "{serial}"
            default: break
            }
        }
        return parts.joined(separator: "/")
    }
}

/** How much confirmation a command waits for: both return once myQ accepts, and the app screen confirms the movement afterwards with GarageEnvironment.followUp. */
public enum CommandProfile: Sendable {
    case siri
    case interactive

    public var followUpReads: Int {
        switch self {
        case .siri: 0
        case .interactive: 0
        }
    }
}

/** Builds the shareable JSON request log: each request's time, method, API host and endpoint template, status and estimated sizes, with totals. */
public enum TrafficExport {
    struct Document: Encodable {
        let format = "whisper-lift-request-log"
        let formatVersion = 1
        let exportedAt: Date
        let appVersion: String
        let sizeNote = "Byte counts estimate the HTTP/1.1 messages the app builds; they exclude headers URLSession adds, TLS framing and compression."
        let totals: Totals
        let requests: [Request]
    }

    struct Totals: Encodable {
        let requests: Int
        let failedRequests: Int
        let requestBytes: Int
        let responseBytes: Int
        let totalBytes: Int
    }

    struct Request: Encodable {
        let time: Date
        let method: String
        let host: String
        let endpoint: String
        let url: String
        let status: Int?
        let requestBytes: Int
        let responseBytes: Int

        enum CodingKeys: String, CodingKey {
            case time, method, host, endpoint, url, status, requestBytes, responseBytes
        }

        // Written out by hand so a request that got no response shows "status": null instead of omitting the key.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(time, forKey: .time)
            try container.encode(method, forKey: .method)
            try container.encode(host, forKey: .host)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(url, forKey: .url)
            try container.encode(status, forKey: .status)
            try container.encode(requestBytes, forKey: .requestBytes)
            try container.encode(responseBytes, forKey: .responseBytes)
        }
    }

    public static func json(_ entries: [TrafficEntry], exportedAt: Date, appVersion: String) throws -> Data {
        let requests = entries.map { entry in
            let endpoint = MeteredTransport.template(entry.path)
            return Request(
                time: entry.date, method: entry.method, host: entry.host, endpoint: endpoint, url: "https://\(entry.host)\(endpoint)", status: entry.status,
                requestBytes: entry.requestBytes, responseBytes: entry.responseBytes
            )
        }
        let sent = requests.map(\.requestBytes).reduce(0, +)
        let received = requests.map(\.responseBytes).reduce(0, +)
        let failed = requests.filter { request in request.status.map { !(200..<300).contains($0) } ?? true }.count
        let document = Document(
            exportedAt: exportedAt, appVersion: appVersion,
            totals: Totals(requests: requests.count, failedRequests: failed, requestBytes: sent, responseBytes: received, totalBytes: sent + received),
            requests: requests
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return try encoder.encode(document)
    }

    /** A file name that sorts by export time, for example whisper-lift-requests-20260921-141500Z.json. */
    public static func fileName(exportedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "whisper-lift-requests-\(formatter.string(from: exportedAt))Z.json"
    }

    // ISO 8601 in UTC rounded to the millisecond, shown only when nonzero; the fraction is formatted from integers because the formatter truncates binary fractions such as 0.6.
    static func timestamp(_ date: Date) -> String {
        let milliseconds = Int((date.timeIntervalSince1970 * 1000).rounded())
        let (seconds, fraction) = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let base = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).timeZone(separator: .omitted))
        guard fraction != 0 else { return base }
        return base.dropLast() + String(format: ".%03dZ", fraction)
    }
}
