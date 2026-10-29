import Foundation

public struct HTTPResponse {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    public var text: String { String(data: body, encoding: .utf8) ?? "" }
    public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

public struct HTTPError: Error, CustomStringConvertible {
    public let status: Int
    public let what: String
    public let detail: String
    public var description: String { "\(what) failed with HTTP \(status): \(detail.prefix(300))" }

    public init(status: Int, what: String, detail: String) {
        self.status = status; self.what = what; self.detail = detail
    }
}

/// The app's HTTP layer: one session that never follows redirects on its own, so a token is
/// never carried to another host without us deciding to.
public final class HTTPClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = HTTPClient()
    private var session: URLSession!

    public override convenience init() { self.init(protocolClasses: nil) }

    /// `protocolClasses` lets tests answer requests themselves.
    public init(protocolClasses: [AnyClass]?) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    /// Receives one line per request: method, host and path, status. Never a token, a query or a body,
    /// except the first part of an error answer, which is what explains a failure.
    public nonisolated(unsafe) static var log: (@Sendable (String) -> Void)?

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let what = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(request.url?.path ?? "")"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
            if let log = HTTPClient.log {
                var line = "\(what) -> \(http.statusCode) (\(data.count) bytes)"
                if http.statusCode >= 400 { line += " " + String(decoding: data.prefix(900), as: UTF8.self).replacingOccurrences(of: "\n", with: " ") }
                log(line)
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch {
            HTTPClient.log?("\(what) -> failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func request(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return try await send(request)
    }

    public static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }
}
