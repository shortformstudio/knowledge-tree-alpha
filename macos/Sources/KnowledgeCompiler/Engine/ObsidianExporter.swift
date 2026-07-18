import AppKit
import Foundation

enum ObsidianExporter {
    struct ExportOutcome {
        let fileCount: Int
        let vaultURL: URL
    }

    static var defaultVaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("knowledge compiler vault", isDirectory: true)
    }

    // MARK: - Markdown generation

    static func export(nodes: [PageNode], edges: [GraphEdge], to vaultURL: URL) throws -> ExportOutcome {
        let fm = FileManager.default
        try fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: vaultURL.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)

        var noteNames: [String: String] = [:]
        var titleByName: [String: String] = [:]
        for node in nodes {
            let name = noteName(for: node)
            noteNames[node.id] = name
            titleByName[node.id] = node.title.lowercased()
        }

        var outbound: [String: [String]] = [:]
        var inbound: [String: [String]] = [:]
        for edge in edges {
            guard let sourceName = noteNames[edge.source] else { continue }
            if let targetName = noteNames[edge.target] {
                outbound[edge.source, default: []].append(targetName)
                inbound[edge.target, default: []].append(sourceName)
            }
        }

        let concepts = extractConcepts(from: nodes)
        let dateFormatter = ISO8601DateFormatter()
        var written = 0

        for node in nodes {
            guard let name = noteNames[node.id] else { continue }
            let md = buildNote(
                node: node,
                name: name,
                titleByName: titleByName,
                outbound: outbound[node.id] ?? [],
                inbound: inbound[node.id] ?? [],
                concepts: concepts,
                dateFormatter: dateFormatter
            )
            try md.write(
                to: vaultURL.appendingPathComponent("\(name).md"),
                atomically: true,
                encoding: .utf8
            )
            written += 1
        }

        let indexMD = buildIndex(nodes: nodes, edges: edges, noteNames: noteNames, concepts: concepts, dateFormatter: dateFormatter)
        try indexMD.write(
            to: vaultURL.appendingPathComponent("_trunk index.md"),
            atomically: true,
            encoding: .utf8
        )
        written += 1

        let conceptsMD = buildConceptsPage(concepts: concepts, noteNames: noteNames)
        try conceptsMD.write(
            to: vaultURL.appendingPathComponent("_concepts.md"),
            atomically: true,
            encoding: .utf8
        )
        written += 1

        return ExportOutcome(fileCount: written, vaultURL: vaultURL)
    }

    // MARK: - Per-note builder

    private static func buildNote(
        node: PageNode,
        name: String,
        titleByName: [String: String],
        outbound: [String],
        inbound: [String],
        concepts: [String: ConceptEntry],
        dateFormatter: ISO8601DateFormatter
    ) -> String {
        let linkedConcepts = concepts.filter { _, entry in
            entry.nodes.contains(node.id)
        }.map(\.key).sorted()

        var md = ""
        md += "---\n"
        md += "url: \"\(node.id)\"\n"
        md += "depth: \(node.depth)\n"
        md += "chars: \(node.chars)\n"
        md += "fetched: \(dateFormatter.string(from: node.fetchedAt))\n"
        md += "tags: [knowledge-compiler, depth-\(node.depth)]\n"
        md += "cssclasses: [kc-note]\n"
        if !linkedConcepts.isEmpty {
            md += "concepts: [\(linkedConcepts.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
        }
        md += "---\n\n"

        md += "# \(node.title.lowercased())\n\n"

        md += "> [!abstract] gateway\n"
        md += "> d\(node.depth) · \(node.chars) chars · [source](\(node.id))\n\n"

        if !linkedConcepts.isEmpty {
            md += "> [!tip] concepts\n"
            md += "> \(linkedConcepts.map { "[[_concepts#\($0)|\($0)]]" }.joined(separator: " · "))\n\n"
        }

        md += "## parsed content\n\n"
        if node.excerpt.isEmpty {
            md += "_no text compiled_\n\n"
        } else {
            md += "\(node.excerpt)\n\n"
        }

        if !node.rawText.isEmpty && node.rawText != node.excerpt {
            md += "## raw source\n\n"
            md += "```text\n\(node.rawText)\n```\n\n"
        }

        let allOut = Array(Set(outbound)).sorted()
        let allIn = Array(Set(inbound)).sorted()
        if !allOut.isEmpty || !allIn.isEmpty {
            md += "## connections\n\n"
            if !allOut.isEmpty {
                md += "> [!example] links to\n"
                for link in allOut {
                    md += "> - [[\(link)]]\n"
                }
                md += "\n"
            }
            if !allIn.isEmpty {
                md += "> [!example] linked from\n"
                for link in allIn {
                    md += "> - [[\(link)]]\n"
                }
                md += "\n"
            }
        }

        return md
    }

    // MARK: - Index / graph overview

    private static func buildIndex(
        nodes: [PageNode],
        edges: [GraphEdge],
        noteNames: [String: String],
        concepts: [String: ConceptEntry],
        dateFormatter: ISO8601DateFormatter
    ) -> String {
        var md = ""
        md += "---\n"
        md += "tags: [knowledge-compiler, index]\n"
        md += "cssclasses: [kc-index]\n"
        md += "---\n\n"

        md += "# trunk index\n\n"
        md += "compiled \(nodes.count) memories · \(edges.count) edges · \(dateFormatter.string(from: Date()))\n\n"

        let totalChars = nodes.reduce(0) { $0 + $1.chars }
        md += "**\(nodes.count)** pages across **\(nodes.map(\.depth).max() ?? 0 + 1)** depth levels · **\(totalChars)** total chars\n\n"

        md += "## graph\n\n"
        md += "```mermaid\ngraph TD\n"
        for depth in 0...3 {
            let level = nodes.filter { $0.depth == depth }
            if !level.isEmpty {
                md += "  subgraph depth\(depth)[d\(depth)]\n"
                for node in level {
                    if let name = noteNames[node.id] {
                        let escaped = name.replacingOccurrences(of: "\"", with: "")
                        md += "    \(nodeHash(node.id))[\"\(escaped)\"]\n"
                    }
                }
                md += "  end\n"
            }
        }
        for edge in edges {
            md += "  \(nodeHash(edge.source)) --> \(nodeHash(edge.target))\n"
        }
        md += "```\n\n"

        if !concepts.isEmpty {
            md += "## concepts\n\n"
            let sorted = concepts.sorted { $0.value.frequency > $1.value.frequency }
            for (concept, entry) in sorted.prefix(20) {
                md += "- **[[_concepts#\(concept)|\(concept)]]** — \(entry.frequency) mentions\n"
            }
            md += "\n"
        }

        md += "## depth map\n\n"
        for depth in 0...3 {
            let level = nodes.filter { $0.depth == depth }
            guard !level.isEmpty else { continue }
            md += "### \(depth) link\(depth == 1 ? "" : "s") deep\n\n"
            for node in level {
                if let name = noteNames[node.id] {
                    md += "- [[\(name)]]\n"
                }
            }
        }
        md += "\n"

        md += "## dataview\n\n"
        md += "```dataview\n"
        md += "TABLE depth, chars, file.cday as compiled\n"
        md += "FROM \"\"\n"
        md += "WHERE contains(tags, \"knowledge-compiler\")\n"
        md += "SORT depth ASC, file.name ASC\n"
        md += "```\n"

        return md
    }

    // MARK: - Concepts page

    private static func buildConceptsPage(concepts: [String: ConceptEntry], noteNames: [String: String]) -> String {
        var md = ""
        md += "---\n"
        md += "tags: [knowledge-compiler, concepts]\n"
        md += "cssclasses: [kc-concepts]\n"
        md += "---\n\n"

        md += "# detected concepts\n\n"
        md += "auto-extracted semantic threads from the compiled knowledge graph\n\n"

        let sorted = concepts.sorted { $0.value.frequency > $1.value.frequency }
        for (concept, entry) in sorted {
            md += "## \(concept)\n\n"
            md += "**frequency:** \(entry.frequency) mentions across \(entry.nodes.count) page\(entry.nodes.count == 1 ? "" : "s")\n\n"
            md += "### pages\n\n"
            for nodeID in entry.nodes {
                if let name = noteNames[nodeID] {
                    md += "- [[\(name)]]\n"
                }
            }
            md += "\n"
        }

        return md
    }

    // MARK: - Concept extraction

    private struct ConceptEntry {
        var frequency: Int = 0
        var nodes: Set<String> = []
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "are", "was",
        "were", "been", "have", "has", "had", "not", "but", "its", "his",
        "her", "they", "them", "their", "will", "would", "could", "should",
        "about", "which", "when", "what", "who", "how", "all", "each", "more",
        "some", "only", "over", "than", "then", "also", "just", "into", "can",
        "like", "other", "new", "after", "before", "between", "through",
        "because", "being", "does", "said", "your", "may", "any", "very",
        "much", "such", "these", "those", "our", "out", "now", "same",
        "see", "get", "make", "use", "one", "two", "way", "even", "still",
        "back", "well", "own", "part", "take", "know", "think", "good",
        "great", "many", "first", "last", "long", "made", "work", "year",
        "years", "time", "life", "day", "days", "world", "people", "place",
        "things", "thing", "find", "found", "used", "using", "youre", "weve",
        "theyre", "isnt", "dont", "cant", "wont", "didnt", "wouldnt", "shouldnt",
        "couldnt", "hes", "shes", "heres", "theres", "thats", "whats", "whos",
    ]

    private static func extractConcepts(from nodes: [PageNode]) -> [String: ConceptEntry] {
        let minimumLength = 5
        let minimumFrequency = 2

        var phraseCounts: [String: ConceptEntry] = [:]

        for node in nodes {
            let text = node.excerpt.lowercased()
            let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { word in
                    let w = word.trimmingCharacters(in: .whitespaces)
                    return w.count >= minimumLength && !stopWords.contains(w)
                }

            let wordSet = Set(words)
            for word in wordSet {
                let concept = word.capitalized
                var entry = phraseCounts[concept] ?? ConceptEntry()
                entry.frequency += 1
                entry.nodes.insert(node.id)
                phraseCounts[concept] = entry
            }
        }

        return phraseCounts.filter { $0.value.frequency >= minimumFrequency }
    }

    // MARK: - Note naming

    static func noteName(for node: PageNode) -> String {
        var name = node.title.lowercased()
        let forbidden = CharacterSet(charactersIn: "/\\:#^[]|?*\"<>\n\t")
        name = name.components(separatedBy: forbidden).joined(separator: " ")
        name = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        if name.count > 60 { name = String(name.prefix(60)) }
        if name.isEmpty { name = "untitled" }
        let hash = stableHash(node.id)
        return "\(name) \(String(format: "%06x", hash % 0xFFFFFF))"
    }

    private static func stableHash(_ text: String) -> Int {
        var hash = 5381
        for byte in text.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }

    private static func nodeHash(_ id: String) -> String {
        "n\(String(format: "%06x", stableHash(id) % 0xFFFFFF))"
    }

    // MARK: - Obsidian integration

    static var obsidianConfigURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("obsidian/obsidian.json")
    }

    static func obsidianInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://open")!) != nil
    }

    @discardableResult
    static func registerVault(at vaultURL: URL) throws -> Bool {
        let configURL = obsidianConfigURL
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var vaults = root["vaults"] as? [String: Any] ?? [:]
        let path = vaultURL.path
        for value in vaults.values {
            if let vault = value as? [String: Any], vault["path"] as? String == path {
                return false
            }
        }
        let id = (0..<16).map { _ in String(format: "%x", Int.random(in: 0...15)) }.joined()
        vaults[id] = ["path": path, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        root["vaults"] = vaults
        let data = try JSONSerialization.data(withJSONObject: root, options: [])
        try data.write(to: configURL, options: .atomic)
        return true
    }

    static func openVault(_ vaultURL: URL) -> Bool {
        let name = vaultURL.lastPathComponent
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "obsidian://open?vault=\(encoded)") else { return false }
        return NSWorkspace.shared.open(url)
    }
}
