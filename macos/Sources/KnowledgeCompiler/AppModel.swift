import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let log = SystemLog()
    let graphManager = GraphManager()

    @Published var urlText = ""
    @Published var depth = 2
    @Published var sameDomainOnly = true
    @Published var isCrawling = false
    @Published var lastSummary: CrawlSummary?
    @Published var selectedNodeID: String?

    @Published var isScraping = false
    @Published var lastScrapeResult: ProfileScrapeResult?

    private var crawlTask: Task<Void, Never>?
    private var scrapeTask: Task<Void, Never>?

    var activeGraph: GraphStore? { graphManager.activeGraph }

    var forestTreeEntries: [ForestTreeEntry] {
        graphManager.graphs.map { meta in
            let urls = meta.sourceURLs
            let host = urls.first.flatMap { URL(string: $0)?.host?.lowercased() } ?? ""
            let species: TreeSpecies = {
                if host.contains("threads") || host.contains("twitter") || host.contains("x.com") { return .cedar }
                if host.contains("github") { return .ash }
                if host.contains("docs") || host.contains("wiki") { return .beech }
                return .birch
            }()
            return ForestTreeEntry(
                id: meta.id,
                title: meta.title,
                nodeCount: meta.nodeCount,
                edgeCount: meta.edgeCount,
                species: species
            )
        }
    }

    init() {
        if graphManager.graphs.isEmpty {
            _ = graphManager.newGraph(title: "untitled")
        } else {
            graphManager.activateGraph(id: graphManager.graphs[0].id)
        }

        if let g = graphManager.activeGraph, g.nodeCount > 0 {
            log.post(.info, "graph", "restored \(g.nodeCount) nodes, \(g.edgeCount) edges")
        }
        log.post(.info, "system", "knowledge compiler online")
    }

    // MARK: - Graph management

    func newGraph(title: String) {
        _ = graphManager.newGraph(title: title)
        log.post(.info, "system", "new graph created — \(title)")
    }

    func activateGraph(id: UUID) {
        graphManager.activateGraph(id: id)
        if let g = graphManager.activeGraph {
            log.post(.info, "system", "activated graph — \(g.nodeCount) nodes, \(g.edgeCount) edges")
        }
        selectedNodeID = nil
    }

    func saveGraph() {
        if graphManager.saveActiveGraph() {
            if let meta = graphManager.graphs.first(where: { $0.id == graphManager.activeGraphID }) {
                log.post(.success, "graph", "saved — \(meta.title) (\(meta.nodeCount) nodes, \(meta.edgeCount) edges)")
            }
        } else {
            log.post(.error, "graph", "save failed")
        }
    }

    func deleteGraph(id: UUID) {
        let title = graphManager.graphs.first(where: { $0.id == id })?.title ?? "unknown"
        graphManager.deleteGraph(id: id)
        log.post(.warn, "system", "deleted graph — \(title)")
    }

    // MARK: - Crawling

    func startCrawl() {
        guard !isCrawling else { return }
        let target = urlText.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            log.post(.error, "system", "no url provided")
            return
        }
        guard let graph = graphManager.activeGraph else {
            log.post(.error, "system", "no active graph — create one first")
            return
        }
        guard let gid = graphManager.activeGraphID else { return }

        graphManager.addSourceURL(target, to: gid)
        isCrawling = true
        lastSummary = nil

        let log = self.log
        let crawler = Crawler(
            log: log,
            onNode: { node in
                Task { @MainActor in graph.addNode(node) }
            },
            onEdge: { source, target in
                Task { @MainActor in graph.addEdge(source: source, target: target) }
            }
        )
        var cfg = CrawlConfiguration(depth: depth)
        cfg.sameDomainOnly = sameDomainOnly

        crawlTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.finishCrawl() } }
            do {
                let summary = try await crawler.crawl(start: target, config: cfg)
                await MainActor.run { [weak self] in self?.lastSummary = summary }
            } catch is CancellationError {
                log.emit(.warn, "crawler", "crawl cancelled")
            } catch {
                log.emit(.error, "crawler", "\(error)")
            }
        }
    }

    func stopCrawl() {
        crawlTask?.cancel()
        log.post(.warn, "system", "stop requested")
    }

    private func finishCrawl() {
        isCrawling = false
        crawlTask = nil
        saveGraph()
    }

    // MARK: - Profile scraping

    func startProfileScrape(url raw: String) {
        guard !isScraping else { return }
        let target = raw.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        var urlStr = target
        if !urlStr.lowercased().hasPrefix("http://") && !urlStr.lowercased().hasPrefix("https://") {
            urlStr = "https://" + urlStr
        }
        guard let url = URL(string: urlStr) else {
            log.post(.error, "scraper", "invalid url — \(target)")
            return
        }

        isScraping = true
        lastScrapeResult = nil

        let log = self.log
        let scraper = ProfileScraper(log: log)

        scrapeTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.finishScrape() } }
            do {
                let result = try await scraper.scrape(url: url)
                await MainActor.run { [weak self] in self?.lastScrapeResult = result }
            } catch is CancellationError {
                scraper.teardown()
                log.emit(.warn, "scraper", "profile scrape cancelled")
            } catch {
                scraper.teardown()
                log.emit(.error, "scraper", "\(error.localizedDescription)")
            }
        }
    }

    func cancelProfileScrape() {
        scrapeTask?.cancel()
        log.post(.warn, "scraper", "stop requested")
    }

    private func finishScrape() {
        isScraping = false
        scrapeTask = nil
    }

    func openThreadsLogin() {
        let scraper = ProfileScraper(log: log)
        scraper.openThreadsLogin()
    }

    // MARK: - Node selection

    func selectNode(id: String) {
        guard let graph = graphManager.activeGraph,
              graph.nodes.contains(where: { $0.id == id }) else { return }
        selectedNodeID = id
        if let node = selectedNode {
            log.post(.info, "trunk", "gateway opened — \(node.title.lowercased())")
        }
    }

    var selectedNode: PageNode? {
        guard let id = selectedNodeID else { return nil }
        return graphManager.activeGraph?.nodes.first { $0.id == id }
    }

    func closeReader() {
        selectedNodeID = nil
    }

    func openFloatingReader(for node: PageNode) {
        let title = graphManager.graphs.first(where: { $0.id == graphManager.activeGraphID })?.title ?? "knowledge compiler"
        let window = FloatingReaderWindow(node: node, graphTitle: title)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Obsidian export

    @discardableResult
    func exportMarkdown() -> ObsidianExporter.ExportOutcome? {
        guard let graph = graphManager.activeGraph, graph.nodeCount > 0 else {
            log.post(.error, "export", "graph is empty")
            return nil
        }
        do {
            let outcome = try ObsidianExporter.export(
                nodes: graph.nodes,
                edges: graph.edges,
                to: ObsidianExporter.defaultVaultURL
            )
            log.post(.success, "export", "\(outcome.fileCount) .md notes → \(outcome.vaultURL.path)")
            return outcome
        } catch {
            log.post(.error, "export", "markdown export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func exportToObsidian() {
        guard let outcome = exportMarkdown() else { return }
        guard ObsidianExporter.obsidianInstalled() else {
            log.post(.error, "export", "obsidian not found — revealing vault in finder")
            NSWorkspace.shared.open(outcome.vaultURL)
            return
        }
        do {
            let registered = try ObsidianExporter.registerVault(at: outcome.vaultURL)
            if registered {
                log.post(.info, "export", "vault registered with obsidian")
            }
        } catch {
            log.post(.warn, "export", "vault registration failed: \(error.localizedDescription)")
        }
        if ObsidianExporter.openVault(outcome.vaultURL) {
            log.post(.success, "export", "obsidian opening vault")
        } else {
            NSWorkspace.shared.open(outcome.vaultURL)
        }
    }
}
