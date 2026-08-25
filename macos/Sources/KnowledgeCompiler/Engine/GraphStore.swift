import Foundation

struct PageNode: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let depth: Int
    let chars: Int
    let excerpt: String
    let rawText: String
    let fetchedAt: Date
    let crawlId: String?
    let parentUrl: String?
    let crawlOrder: Int

    init(
        id: String,
        title: String,
        depth: Int,
        chars: Int,
        excerpt: String = "",
        rawText: String = "",
        fetchedAt: Date = Date(),
        crawlId: String? = nil,
        parentUrl: String? = nil,
        crawlOrder: Int = 0
    ) {
        self.id = id
        self.title = title
        self.depth = depth
        self.chars = chars
        self.excerpt = excerpt
        self.rawText = rawText
        self.fetchedAt = fetchedAt
        self.crawlId = crawlId
        self.parentUrl = parentUrl
        self.crawlOrder = crawlOrder
    }
}

struct GraphEdge: Codable, Sendable, Hashable {
    let source: String
    let target: String

    static func == (lhs: GraphEdge, rhs: GraphEdge) -> Bool {
        lhs.source == rhs.source && lhs.target == rhs.target
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(target)
    }
}

struct CrawlSession: Identifiable, Codable, Sendable {
    let id: String
    let startUrl: String
    let startTime: Date
    let maxDepth: Int
    let nodesCount: Int
    let edgesCount: Int

    var title: String {
        let host = URL(string: startUrl)?.host ?? startUrl
        return "\(host) · \(nodesCount) nodes · \(edgesCount) edges"
    }
}

@MainActor
final class GraphStore: ObservableObject {
    @Published private(set) var nodes: [PageNode] = []
    @Published private(set) var edges: [GraphEdge] = []
    @Published private(set) var crawlSessions: [CrawlSession] = []

    private var nodeIndex: [String: Int] = [:]
    private var edgeSet: Set<GraphEdge> = []
    private var sessionIndex: [String: Int] = [:]

    var storageID: UUID?

    var nodeCount: Int { nodes.count }
    var edgeCount: Int { edges.count }

    init() {}

    func addNode(_ node: PageNode) {
        if let existing = nodeIndex[node.id] {
            nodes[existing] = node
        } else {
            nodeIndex[node.id] = nodes.count
            nodes.append(node)
        }
    }

    func addEdge(source: String, target: String) {
        let edge = GraphEdge(source: source, target: target)
        if edgeSet.insert(edge).inserted {
            edges.append(edge)
        }
    }

    func addCrawlSession(_ session: CrawlSession) {
        if let existing = sessionIndex[session.id] {
            crawlSessions[existing] = session
        } else {
            sessionIndex[session.id] = crawlSessions.count
            crawlSessions.append(session)
        }
    }

    func getCrawlTree(for sessionId: String) -> (nodes: [PageNode], edges: [GraphEdge]) {
        let treeNodes = nodes.filter { $0.crawlId == sessionId }
        let nodeIds = Set(treeNodes.map { $0.id })
        let treeEdges = edges.filter { nodeIds.contains($0.source) && nodeIds.contains($0.target) }
        return (treeNodes.sorted { $0.crawlOrder < $1.crawlOrder }, treeEdges)
    }

    func getAllCrawlTrees() -> [(CrawlSession, [PageNode], [GraphEdge])] {
        return crawlSessions.map { session in
            let (nodes, edges) = getCrawlTree(for: session.id)
            return (session, nodes, edges)
        }
    }

    func clear() {
        nodes.removeAll()
        edges.removeAll()
        crawlSessions.removeAll()
        nodeIndex.removeAll()
        edgeSet.removeAll()
        sessionIndex.removeAll()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        let nodes: [PageNode]
        let edges: [GraphEdge]
        let crawlSessions: [CrawlSession]
        let savedAt: Date
    }

    static func storageURL(for id: UUID) -> URL {
        let base = baseDirectory
        return base.appendingPathComponent("graph_\(id.uuidString).json")
    }

    private static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeCompiler", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var storageURL: URL {
        baseDirectory.appendingPathComponent("graph.json")
    }

    func save() throws {
        let url = storageID.map { Self.storageURL(for: $0) } ?? Self.storageURL
        let snapshot = Snapshot(nodes: nodes, edges: edges, crawlSessions: crawlSessions, savedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    func load() throws {
        let url = storageID.map { Self.storageURL(for: $0) } ?? Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: url))
        clear()
        snapshot.nodes.forEach { addNode($0) }
        snapshot.edges.forEach { addEdge(source: $0.source, target: $0.target) }
        snapshot.crawlSessions.forEach { addCrawlSession($0) }
    }
}