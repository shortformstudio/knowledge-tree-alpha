import Foundation

enum SelfTest {
    private actor Collector {
        var nodes: [PageNode] = []
        var edges: [(String, String)] = []
        func addNode(_ node: PageNode) { nodes.append(node) }
        func addEdge(_ source: String, _ target: String) { edges.append((source, target)) }
    }

    static func run(startURL: String, depth: Int) async -> Bool {
        let log = ConsoleLogSink()
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                passed += 1
                log.emit(.success, "selftest", "PASS — \(name)")
            } else {
                failed += 1
                log.emit(.error, "selftest", "FAIL — \(name)")
            }
        }

        log.emit(.info, "selftest", "knowledge compiler end-to-end self test — blueprint: \(startURL) @ depth \(depth)")

        // 1. Parser unit checks
        let parser = HTMLParser()
        let sampleHTML = """
        <html><head><title>Sample &amp; Title</title><style>body{color:red}</style></head>
        <body><nav><a href="/nav">nav</a></nav>
        <p>hello <b>world</b> &mdash; knowledge</p>
        <a href="/docs/page1">one</a>
        <a href="https://example.com/docs/page2#frag">two</a>
        <a href="https://other.com/external">ext</a>
        <a href="mailto:x@y.z">mail</a>
        <a href="/asset.png">img</a>
        <script>var x = "<a href='/fake'>no</a>";</script>
        </body></html>
        """
        let parsed = parser.extract(
            html: sampleHTML,
            baseURL: URL(string: "https://example.com/docs/")!,
            sameDomainOnly: true
        )
        check("parser: title decoded", parsed.title == "Sample & Title")
        check("parser: text extracted, tags stripped", parsed.text.contains("hello world — knowledge"))
        check("parser: script content excluded", !parsed.text.contains("var x"))
        check(
            "parser: same-domain links resolved, nav stripped, fragment removed (found \(parsed.links.count))",
            parsed.links.map(\.absoluteString).sorted() == [
                "https://example.com/docs/page1",
                "https://example.com/docs/page2",
            ]
        )

        // 2. Error-path checks — every failure mode must throw a described error
        let silentCollector = Collector()
        let errCrawler = Crawler(
            log: log,
            onNode: { node in Task { await silentCollector.addNode(node) } },
            onEdge: { s, t in Task { await silentCollector.addEdge(s, t) } }
        )

        do {
            _ = try await errCrawler.crawl(start: "   ", config: CrawlConfiguration(depth: 1))
            check("errors: empty url rejected", false)
        } catch {
            check("errors: empty url rejected (\(error))", error is FetchError)
        }

        let unreachable = try? await errCrawler.crawl(
            start: "https://definitely-not-a-real-host-4dffd2.invalid",
            config: CrawlConfiguration(depth: 1)
        )
        check(
            "errors: unreachable host surfaces as logged error, crawl survives",
            unreachable != nil && unreachable!.errors == 1 && unreachable!.pages == 0
        )

        // 3. Depth clamping
        check("config: depth clamps to 1...3", CrawlConfiguration(depth: 9).depth == 3 && CrawlConfiguration(depth: 0).depth == 1)

        // 4. Live end-to-end crawl against the blueprint
        let collector = Collector()
        let crawler = Crawler(
            log: log,
            onNode: { node in Task { await collector.addNode(node) } },
            onEdge: { s, t in Task { await collector.addEdge(s, t) } }
        )
        do {
            let summary = try await crawler.crawl(start: startURL, config: CrawlConfiguration(depth: depth))
            try? await Task.sleep(nanoseconds: 200_000_000)
            let nodes = await collector.nodes
            let edges = await collector.edges

            check("live: root page compiled", nodes.contains { $0.depth == 0 })
            check("live: \(summary.pages) pages compiled (> 0)", summary.pages > 0)
            check("live: node callbacks delivered (\(nodes.count))", nodes.count == summary.pages)
            check("live: edge callbacks delivered (\(edges.count))", edges.count == summary.edges)
            check("live: depth ceiling respected", nodes.allSatisfy { $0.depth <= depth })
            check("live: content extracted from root", (nodes.first { $0.depth == 0 }?.chars ?? 0) > 50)
            if depth >= 1 {
                check("live: crawl went ≥ 1 link deep", summary.deepestDepth >= 1 || summary.edges == 0)
            }

            log.emit(.info, "selftest", "sample of compiled knowledge:")
            for node in nodes.prefix(5) {
                log.emit(.info, "selftest", "  [d\(node.depth)] \(node.title) — \(node.excerpt.prefix(110))…")
            }
        } catch {
            check("live: crawl completed (\(error))", false)
        }

        log.emit(
            failed == 0 ? .success : .error,
            "selftest",
            "verdict: \(passed) passed, \(failed) failed"
        )
        return failed == 0
    }
}
