import Foundation

enum FetchError: Error, CustomStringConvertible {
    case invalidURL(String)
    case unsupportedScheme(String)
    case httpStatus(Int, URL)
    case notHTML(String, URL)
    case tooLarge(Int, URL)
    case timeout(URL)
    case transport(String, URL)

    var description: String {
        switch self {
        case .invalidURL(let s): return "invalid url: \(s)"
        case .unsupportedScheme(let s): return "unsupported scheme: \(s) (http/https only)"
        case .httpStatus(let code, let url): return "http \(code) — \(url.absoluteString)"
        case .notHTML(let type, let url): return "skipped non-html (\(type)) — \(url.absoluteString)"
        case .tooLarge(let bytes, let url): return "page too large (\(bytes) bytes) — \(url.absoluteString)"
        case .timeout(let url): return "timeout — \(url.absoluteString)"
        case .transport(let reason, let url): return "transport failure: \(reason) — \(url.absoluteString)"
        }
    }
}

struct FetchResult: Sendable {
    let html: String
    let finalURL: URL
    let bytes: Int
}

actor Fetcher {
    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    private let maxBytes: Int
    private let maxRetries: Int
    private let log: LogSink

    private var lastRequest: [String: Date] = [:]

    init(
        userAgent: String = "knowledge-compiler/1.0 (+research; contact: local)",
        timeout: TimeInterval = 15,
        minInterval: TimeInterval = 0.4,
        maxBytes: Int = 3_000_000,
        maxRetries: Int = 2,
        log: LogSink
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "text/html,application/xhtml+xml"]
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
        self.minInterval = minInterval
        self.maxBytes = maxBytes
        self.maxRetries = maxRetries
        self.log = log
    }

    func fetch(_ url: URL) async throws -> FetchResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FetchError.unsupportedScheme(url.scheme ?? "none")
        }
        try await throttle(host: url.host ?? "")

        var attempt = 0
        while true {
            do {
                return try await request(url)
            } catch let error as FetchError {
                switch error {
                case .timeout, .transport, .httpStatus(500...599, _):
                    if attempt < maxRetries {
                        attempt += 1
                        let backoff = 0.5 * pow(2.0, Double(attempt - 1))
                        log.emit(.warn, "fetcher", "retry \(attempt)/\(maxRetries) in \(String(format: "%.1f", backoff))s — \(url.absoluteString)")
                        try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        continue
                    }
                    throw error
                default:
                    throw error
                }
            }
        }
    }

    private func request(_ url: URL) async throws -> FetchResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw FetchError.timeout(url)
        } catch {
            throw FetchError.transport(error.localizedDescription, url)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-http response", url)
        }
        guard (200...299).contains(http.statusCode) else {
            throw FetchError.httpStatus(http.statusCode, url)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !contentType.isEmpty,
           !contentType.contains("text/html"),
           !contentType.contains("application/xhtml") {
            throw FetchError.notHTML(contentType, url)
        }
        guard data.count <= maxBytes else {
            throw FetchError.tooLarge(data.count, url)
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return FetchResult(html: html, finalURL: http.url ?? url, bytes: data.count)
    }

    private func throttle(host: String) async throws {
        guard minInterval > 0 else { return }
        let now = Date()
        if let last = lastRequest[host] {
            let wait = minInterval - now.timeIntervalSince(last)
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        lastRequest[host] = Date()
    }
}
