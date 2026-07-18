import Foundation

struct PageNode: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let depth: Int
    let chars: Int
    let excerpt: String
    let rawText: String
    let fetchedAt: Date
}

struct GraphEdge: Codable, Sendable, Hashable {
    let source: String
    let target: String
}

@MainActor
final class GraphStore: ObservableObject {
    @Published private(set) var nodes: [PageNode] = []
    @Published private(set) var edges: [GraphEdge] = []

    private var nodeIndex: [String: Int] = [:]
    private var edgeSet: Set<GraphEdge> = []

    var storageID: UUID?

    var nodeCount: Int { nodes.count }
    var edgeCount: Int { edges.count }

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

    func clear() {
        nodes.removeAll()
        edges.removeAll()
        nodeIndex.removeAll()
        edgeSet.removeAll()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        let nodes: [PageNode]
        let edges: [GraphEdge]
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
        let snapshot = Snapshot(nodes: nodes, edges: edges, savedAt: Date())
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
    }
}
