import Foundation

struct CrawlSummary: Sendable {
    var pages = 0
    var edges = 0
    var errors = 0
    var skipped = 0
    var deepestDepth = 0
    var duration: TimeInterval = 0
}

struct CrawlConfiguration: Sendable {
    var depth: Int
    var sameDomainOnly: Bool = true
    var maxPages: Int = Int.max
    var maxConcurrent: Int = 8
    var maxLinksPerPage: Int = Int.max
    var maxExcerptChars: Int = Int.max
    var maxRawChars: Int = Int.max
    var maxPageBytes: Int = Int.max
    var respectRobots: Bool = true
    var filterNav: Bool = true
    var filterFooter: Bool = true
    var filterScripts: Bool = true
    var filterStyles: Bool = true

    init(depth: Int) {
        self.depth = max(depth, 1)
    }
}

final class Crawler: Sendable {
    private let log: LogSink
    private let onNode: @Sendable (PageNode) -> Void
    private let onEdge: @Sendable (String, String) -> Void

    init(
        log: LogSink,
        onNode: @escaping @Sendable (PageNode) -> Void,
        onEdge: @escaping @Sendable (String, String) -> Void
    ) {
        self.log = log
        self.onNode = onNode
        self.onEdge = onEdge
    }

    func crawl(start: String, config: CrawlConfiguration) async throws -> CrawlSummary {
        let fetcher = Fetcher(
            maxBytes: config.maxPageBytes,
            respectRobots: config.respectRobots,
            log: log
        )
        let parser = HTMLParser(
            filterNav: config.filterNav,
            filterFooter: config.filterFooter,
            filterScripts: config.filterScripts,
            filterStyles: config.filterStyles
        )
        guard let startURL = normalize(start) else {
            log.emit(.error, "crawler", FetchError.invalidURL(start).description)
            throw FetchError.invalidURL(start)
        }

        let began = Date()
        var summary = CrawlSummary()
        var visited = Set<String>()
        var frontier: [URL] = [startURL]

        log.emit(.info, "crawler", "crawl begins — \(startURL.absoluteString) · \(config.depth) link\(config.depth == 1 ? "" : "s") deep · cap \(config.maxPages) pages")

        for depth in 0...config.depth {
            if frontier.isEmpty { break }
            try Task.checkCancellation()

            let level = frontier.filter { visited.insert($0.absoluteString).inserted }
                .prefix(max(0, config.maxPages - summary.pages))
            frontier = []
            guard !level.isEmpty else { break }

            log.emit(.info, "crawler", "depth \(depth): fetching \(level.count) page\(level.count == 1 ? "" : "s")")

            let results = await fetchLevel(Array(level), depth: depth, config: config, fetcher: fetcher, parser: parser)

            for result in results {
                try Task.checkCancellation()
                switch result.outcome {
                case .failure(let error):
                    if case .notHTML = error {
                        summary.skipped += 1
                        log.emit(.warn, "crawler", "\(error)")
                    } else {
                        summary.errors += 1
                        log.emit(.error, "crawler", "\(error)")
                    }
                case .success(let (page, finalURL, rawHTML)):
                    if config.sameDomainOnly, normalizedHost(finalURL) != normalizedHost(startURL) {
                        summary.skipped += 1
                        log.emit(.warn, "crawler", "skipped off-domain redirect — \(result.url.absoluteString) → \(finalURL.host ?? "?")")
                        continue
                    }
                    let nodeID = finalURL.absoluteString
                    if nodeID != result.url.absoluteString, !visited.insert(nodeID).inserted {
                        summary.skipped += 1
                        log.emit(.info, "crawler", "duplicate via redirect — \(result.url.absoluteString)")
                        continue
                    }
                    summary.pages += 1
                    summary.deepestDepth = max(summary.deepestDepth, depth)
                    let rawFull = parser.rawText(from: rawHTML)
                    let node = PageNode(
                        id: nodeID,
                        title: page.title.isEmpty ? finalURL.host ?? nodeID : page.title,
                        depth: depth,
                        chars: page.text.count,
                        excerpt: String(page.text.prefix(config.maxExcerptChars)),
                        rawText: String(rawFull.prefix(config.maxRawChars)),
                        fetchedAt: Date()
                    )
                    onNode(node)
                    log.emit(.success, "crawler", "compiled [d\(depth)] \(node.title.lowercased()) — \(page.text.count) chars, \(page.links.count) links")

                    if depth < config.depth {
                        for link in page.links.prefix(config.maxLinksPerPage) {
                            onEdge(nodeID, link.absoluteString)
                            summary.edges += 1
                            if !visited.contains(link.absoluteString) {
                                frontier.append(link)
                            }
                        }
                    }
                }
            }

            if summary.pages >= config.maxPages {
                log.emit(.warn, "crawler", "page cap reached (\(config.maxPages)) — frontier truncated")
                break
            }
        }

        summary.duration = Date().timeIntervalSince(began)
        log.emit(
            summary.pages > 0 ? .success : .error,
            "crawler",
            "crawl complete — \(summary.pages) pages, \(summary.edges) edges, \(summary.errors) errors, \(String(format: "%.1f", summary.duration))s"
        )
        return summary
    }

    // MARK: - Level fetching with bounded concurrency

    private struct LevelResult: Sendable {
        let url: URL
        let outcome: Result<(ParsedPage, URL, String), FetchError>
    }

    private func fetchLevel(_ urls: [URL], depth: Int, config: CrawlConfiguration, fetcher: Fetcher, parser: HTMLParser) async -> [LevelResult] {
        await withTaskGroup(of: LevelResult.self) { group in
            var iterator = urls.makeIterator()
            var inFlight = 0

            func enqueue(_ url: URL) {
                group.addTask { [config] in
                    do {
                        let fetched = try await fetcher.fetch(url)
                        let page = parser.extract(
                            html: fetched.html,
                            baseURL: fetched.finalURL,
                            sameDomainOnly: config.sameDomainOnly
                        )
                        return LevelResult(url: url, outcome: .success((page, fetched.finalURL, fetched.html)))
                    } catch let error as FetchError {
                        return LevelResult(url: url, outcome: .failure(error))
                    } catch {
                        return LevelResult(url: url, outcome: .failure(.transport("\(error)", url)))
                    }
                }
            }

            while inFlight < config.maxConcurrent, let url = iterator.next() {
                enqueue(url)
                inFlight += 1
            }

            var results: [LevelResult] = []
            while let result = await group.next() {
                results.append(result)
                if let url = iterator.next() {
                    enqueue(url)
                }
            }
            return results
        }
    }

    private func normalizedHost(_ url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var comps = URLComponents(string: text), comps.host?.isEmpty == false else { return nil }
        comps.fragment = nil
        return comps.url
    }
}
