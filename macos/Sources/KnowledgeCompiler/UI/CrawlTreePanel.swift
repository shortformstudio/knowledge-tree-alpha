import SwiftUI

struct CrawlTreePanel: View {
    @ObservedObject var model: AppModel

    @State private var selectedSessionId: String?
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            if model.activeGraph?.crawlSessions.isEmpty ?? true {
                emptyState
            } else {
                HStack(spacing: 0) {
                    sessionSidebar
                    Divider().overlay(Theme.panelBorder)
                    treeView
                }
            }
        }
        .onAppear {
            if selectedSessionId == nil,
               let first = model.activeGraph?.crawlSessions.first {
                selectedSessionId = first.id
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tree")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
            Text("no crawl sessions recorded")
                .font(Theme.display(16))
                .foregroundStyle(Theme.textSecondary)
            Text("run a scrape to generate crawl trees")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("crawl sessions")
                .font(Theme.body(10))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider().overlay(Theme.panelBorder)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.activeGraph?.crawlSessions ?? []) { session in
                        SessionRow(
                            session: session,
                            isSelected: selectedSessionId == session.id
                        ) {
                            selectedSessionId = session.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 220)
        .background(Theme.panelBG)
    }

    private var treeView: some View {
        Group {
            if let sessionId = selectedSessionId,
               let graph = model.activeGraph,
               let session = graph.crawlSessions.first(where: { $0.id == sessionId }) {
                let (nodes, edges) = graph.getCrawlTree(for: sessionId)

                VStack(spacing: 0) {
                    headerBar(session: session, nodes: nodes, edges: edges)

                    Divider().overlay(Theme.panelBorder)

                    if nodes.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tree")
                                .font(.system(size: 28, weight: .ultraLight))
                                .foregroundStyle(Theme.textSecondary.opacity(0.4))
                            Text("empty crawl tree")
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            CrawlTreeView(
                                nodes: nodes,
                                edges: edges,
                                onSelectNode: { node in
                                    model.selectNode(id: node.id)
                                    if let selected = model.selectedNode {
                                        model.openFloatingReader(for: selected)
                                    }
                                }
                            )
                            .padding(16)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(Theme.textSecondary.opacity(0.4))
                    Text("select a crawl session")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func headerBar(session: CrawlSession, nodes: [PageNode], edges: [GraphEdge]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startUrl)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("depth \(session.maxDepth) · \(nodes.count) nodes · \(edges.count) edges")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                showDetails.toggle()
            } label: {
                Label(showDetails ? "hide details" : "show details", systemImage: showDetails ? "eye.slash" : "eye")
                    .font(Theme.body(10))
            }
            .buttonStyle(StitchedButtonStyle(prominent: false))

            Button {
                if let url = URL(string: session.startUrl) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("open root", systemImage: "arrow.up.right.square")
                    .font(Theme.body(10))
            }
            .buttonStyle(StitchedButtonStyle(prominent: false))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panelBG.opacity(0.6))
    }
}

private struct SessionRow: View {
    let session: CrawlSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.startUrl)
                    .font(Theme.body(11))
                    .foregroundStyle(isSelected ? Theme.cyan : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text("d\(session.maxDepth)")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.cyan.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.cyan.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text("\(session.nodesCount)n")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.aqua.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.aqua.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text("\(session.edgesCount)e")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.teal.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.teal.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Theme.cyan.opacity(0.1)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                isSelected
                    ? RoundedRectangle(cornerRadius: 6).stroke(Theme.cyan.opacity(0.3), lineWidth: 1)
                    : nil
            )
        }
        .buttonStyle(.plain)
    }
}

struct CrawlTreeView: View {
    let nodes: [PageNode]
    let edges: [GraphEdge]
    let onSelectNode: (PageNode) -> Void

    @State private var hoveredNodeId: String?

    var body: some View {
        let tree = buildTree(nodes: nodes, edges: edges)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(tree.roots, id: \.node.id) { root in
                TreeNodeView(
                    treeNode: root,
                    depth: 0,
                    isLast: root == tree.roots.last,
                    hoveredId: $hoveredNodeId,
                    onSelect: onSelectNode
                )
            }
        }
    }

    private func buildTree(nodes: [PageNode], edges: [GraphEdge]) -> Tree {
        var children: [String: [TreeNode]] = [:]
        var parents: [String: String] = [:]

        for edge in edges {
            children[edge.source, default: []].append(
                TreeNode(node: nodes.first { $0.id == edge.target }!, children: [])
            )
            parents[edge.target] = edge.source
        }

        let roots = nodes
            .filter { parents[$0.id] == nil }
            .map { TreeNode(node: $0, children: children[$0.id] ?? []) }

        return Tree(roots: roots)
    }
}

private struct Tree {
    let roots: [TreeNode]
}

private struct TreeNode: Equatable {
    let node: PageNode
    let children: [TreeNode]

    static func == (lhs: TreeNode, rhs: TreeNode) -> Bool {
        lhs.node.id == rhs.node.id
    }
}

private struct TreeNodeView: View {
    let treeNode: TreeNode
    let depth: Int
    let isLast: Bool
    @Binding var hoveredId: String?
    let onSelect: (PageNode) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                connectorLine
                    .frame(width: 20)

                nodeContent
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(treeNode.node)
            }

            if isExpanded && !treeNode.children.isEmpty {
                HStack(spacing: 0) {
                    verticalLine
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(treeNode.children.enumerated()), id: \.element.node.id) { idx, child in
                            TreeNodeView(
                                treeNode: child,
                                depth: depth + 1,
                                isLast: idx == treeNode.children.count - 1,
                                hoveredId: $hoveredId,
                                onSelect: onSelect
                            )
                        }
                    }
                }
            }
        }
    }

    private var connectorLine: some View {
        VStack(spacing: 0) {
            if depth > 0 {
                Rectangle()
                    .fill(isLast ? Theme.panelBorder : Theme.textSecondary.opacity(0.2))
                    .frame(width: 1)
            } else {
                Color.clear.frame(width: 1)
            }
        }
    }

    private var verticalLine: some View {
        Rectangle()
            .fill(Theme.textSecondary.opacity(0.15))
            .frame(width: 1)
    }

    private var nodeContent: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: treeNode.children.isEmpty ? "circle" : (isExpanded ? "chevron.down" : "chevron.right"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(treeNode.children.isEmpty ? Theme.textSecondary.opacity(0.3) : Theme.cyan)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(treeNode.children.isEmpty ? 0.3 : 1)

            Circle()
                .fill(depthColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(hoveredId == treeNode.node.id ? Theme.cyan : Color.clear, lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(treeNode.node.title.lowercased())
                    .font(Theme.body(12))
                    .foregroundStyle(hoveredId == treeNode.node.id ? Theme.cyan : Theme.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("d\(treeNode.node.depth)")
                        .font(Theme.mono(8))
                        .foregroundStyle(depthColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(depthColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    Text("\(treeNode.node.chars)c")
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))

                    if let crawlId = treeNode.node.crawlId {
                        Text("#\(crawlId.prefix(6))")
                            .font(Theme.mono(7))
                            .foregroundStyle(Theme.textSecondary.opacity(0.4))
                    }
                }
            }

            Spacer()

            if hoveredId == treeNode.node.id {
                Button {
                    onSelect(treeNode.node)
                } label: {
                    Image(systemName: "arrow.up.right.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.cyan)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            hoveredId == treeNode.node.id
                ? Color.white.opacity(0.04)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hoveredId = $0 ? treeNode.node.id : nil }
    }

    private var depthColor: Color {
        switch treeNode.node.depth {
        case 0: return Theme.cyan
        case 1: return Theme.aqua
        case 2: return Theme.teal
        default: return Theme.orange
        }
    }
}