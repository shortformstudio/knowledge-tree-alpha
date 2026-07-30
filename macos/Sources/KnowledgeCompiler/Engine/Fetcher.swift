import Foundation

// MARK: - Robots.txt checker (standard scraping methodology)

enum RobotsTxtChecker {
    private static var cache: [String: Set<String>] = [:]
    private static var cacheTime: [String: Date] = [:]
    private static let cacheTTL: TimeInterval = 300

    static func isAllowed(url: URL, userAgent: String = "*") async -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }

        if let cached = cache[host], let ts = cacheTime[host], Date().timeIntervalSince(ts) < cacheTTL {
            return cached.contains(url.path) || cached.contains("*")
        }

        guard let robotsURL = URL(string: "\(scheme)://\(host)/robots.txt") else { return true }

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(from: robotsURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return true }

            let text = String(data: data, encoding: .utf8) ?? ""
            let disallowed = parseRobotsTxt(text, forUserAgent: userAgent)
            cache[host] = disallowed
            cacheTime[host] = Date()
            return !disallowed.contains(url.path) && !disallowed.contains("*")
        } catch {
            return true
        }
    }

    private static func parseRobotsTxt(_ text: String, forUserAgent targetAgent: String) -> Set<String> {
        var currentAgent = "*"
        var disallowed: Set<String> = []
        var inRelevantBlock = true

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            switch key {
            case "user-agent":
                currentAgent = value.lowercased()
                inRelevantBlock = (currentAgent == targetAgent.lowercased() || currentAgent == "*")
            case "disallow" where inRelevantBlock:
                if value.isEmpty {
                    disallowed = []
                } else {
                    disallowed.insert(value)
                }
            default:
                break
            }
        }

        return disallowed
    }
}

// MARK: - Errors

enum FetchError: Error, CustomStringConvertible {
    case invalidURL(String)
    case unsupportedScheme(String)
    case httpStatus(Int, URL)
    case notHTML(String, URL)
    case tooLarge(Int, URL)
    case timeout(URL)
    case transport(String, URL)
    case robotsDisallowed(URL)

    var description: String {
        switch self {
        case .invalidURL(let s): return "invalid url: \(s)"
        case .unsupportedScheme(let s): return "unsupported scheme: \(s) (http/https only)"
        case .httpStatus(let code, let url): return "http \(code) — \(url.absoluteString)"
        case .notHTML(let type, let url): return "skipped non-html (\(type)) — \(url.absoluteString)"
        case .tooLarge(let bytes, let url): return "page too large (\(bytes) bytes) — \(url.absoluteString)"
        case .timeout(let url): return "timeout — \(url.absoluteString)"
        case .transport(let reason, let url): return "transport failure: \(reason) — \(url.absoluteString)"
        case .robotsDisallowed(let url): return "robots.txt disallowed — \(url.absoluteString)"
        }
    }
}

// MARK: - Fetch result

struct FetchResult: Sendable {
    let html: String
    let finalURL: URL
    let bytes: Int
}

// MARK: - Fetcher

actor Fetcher {
    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    private let maxBytes: Int
    private let maxRetries: Int
    private let log: LogSink
    private let respectRobots: Bool

    private var lastRequest: [String: Date] = [:]

    init(
        userAgent: String = "KnowledgeCompiler/1.0 (research crawler; +https://github.com/shortformstudio/knowledge-compiler)",
        timeout: TimeInterval = 30,
        minInterval: TimeInterval = 0.2,
        maxBytes: Int = Int.max,
        maxRetries: Int = 2,
        respectRobots: Bool = true,
        log: LogSink
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        self.session = URLSession(configuration: config)
        self.userAgent = userAgent
        self.minInterval = minInterval
        self.maxBytes = maxBytes
        self.maxRetries = maxRetries
        self.respectRobots = respectRobots
        self.log = log
    }

    func fetch(_ url: URL) async throws -> FetchResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FetchError.unsupportedScheme(url.scheme ?? "none")
        }

        if respectRobots {
            let allowed = await RobotsTxtChecker.isAllowed(url: url, userAgent: userAgent)
            if !allowed {
                log.emit(.warn, "fetcher", "robots.txt disallowed — \(url.absoluteString)")
                throw FetchError.robotsDisallowed(url)
            }
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
        if maxBytes < Int.max, data.count > maxBytes {
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
