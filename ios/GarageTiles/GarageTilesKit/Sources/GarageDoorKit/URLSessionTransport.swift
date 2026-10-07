import Foundation

/** The production transport: myQ hosts only, no cookies or cache, no redirects, bounded time and body size. */
public final class URLSessionTransport: HTTPTransport {
    let session: URLSession
    public let maxBodyBytes: Int

    public convenience init() {
        self.init(configuration: Self.defaultConfiguration())
    }

    init(configuration: URLSessionConfiguration, maxBodyBytes: Int = 1024 * 1024) {
        session = URLSession(configuration: configuration)
        self.maxBodyBytes = maxBodyBytes
    }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard MyQMetadata.isAllowed(request.url) else { throw MyQError.transport }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: NoRedirects())
        } catch {
            throw MyQError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw MyQError.transport }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxBodyBytes {
                    bytes.task.cancel()
                    throw MyQError.malformedResponse
                }
            }
        } catch let error as MyQError {
            throw error
        } catch {
            throw MyQError.transport
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }
}

/** Refuses every redirect so a 3xx is returned to the caller instead of being followed to another host. */
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
