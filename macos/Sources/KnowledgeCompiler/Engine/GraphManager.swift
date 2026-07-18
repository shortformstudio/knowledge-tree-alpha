import Foundation

struct KnowledgeGraphMeta: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var sourceURLs: [String]
    var nodeCount: Int
    var edgeCount: Int

    init(id: UUID = UUID(), title: String, sourceURLs: [String] = [], nodeCount: Int = 0, edgeCount: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.sourceURLs = sourceURLs
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
    }
}

@MainActor
final class GraphManager: ObservableObject {
    @Published var graphs: [KnowledgeGraphMeta] = []
    @Published var activeGraphID: UUID?
    @Published var activeGraph: GraphStore?

    private var graphStores: [UUID: GraphStore] = [:]

    init() {
        loadIndex()
    }

    // MARK: - Lifecycle

    func newGraph(title: String) -> UUID {
        let meta = KnowledgeGraphMeta(title: title)
        graphs.insert(meta, at: 0)
        let store = GraphStore()
        graphStores[meta.id] = store
        saveIndex()
        activateGraph(id: meta.id)
        return meta.id
    }

    func activateGraph(id: UUID) {
        activeGraphID = id
        if let store = graphStores[id] {
            activeGraph = store
        } else {
            let store = GraphStore()
            store.storageID = id
            do {
                try store.load()
            } catch {
                // fresh graph
            }
            graphStores[id] = store
            activeGraph = store
        }
    }

    func saveActiveGraph() -> Bool {
        guard let id = activeGraphID, let store = activeGraph else { return false }
        store.storageID = id
        do {
            try store.save()
        } catch {
            return false
        }
        if let idx = graphs.firstIndex(where: { $0.id == id }) {
            graphs[idx].nodeCount = store.nodeCount
            graphs[idx].edgeCount = store.edgeCount
        }
        saveIndex()
        return true
    }

    func deleteGraph(id: UUID) {
        graphs.removeAll { $0.id == id }
        graphStores.removeValue(forKey: id)
        let url = GraphStore.storageURL(for: id)
        try? FileManager.default.removeItem(at: url)
        if activeGraphID == id {
            activeGraphID = nil
            activeGraph = nil
            if let first = graphs.first {
                activateGraph(id: first.id)
            }
        }
        saveIndex()
    }

    func addSourceURL(_ url: String, to id: UUID) {
        guard let idx = graphs.firstIndex(where: { $0.id == id }) else { return }
        if !graphs[idx].sourceURLs.contains(url) {
            graphs[idx].sourceURLs.append(url)
            saveIndex()
        }
    }

    // MARK: - Persistence

    private static var indexURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeCompiler", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("graph_index.json")
    }

    private func loadIndex() {
        let url = Self.indexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([KnowledgeGraphMeta].self, from: data)
            graphs = decoded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            graphs = []
        }
    }

    private func saveIndex() {
        let url = Self.indexURL
        do {
            let data = try JSONEncoder().encode(graphs)
            try data.write(to: url, options: .atomic)
        } catch {
            // index persistence failure is non-fatal
        }
    }
}
