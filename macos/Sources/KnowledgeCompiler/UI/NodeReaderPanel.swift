import AppKit
import SwiftUI

struct NodeReaderPanel: View {
    @ObservedObject var model: AppModel
    let node: PageNode
    @State private var viewMode: ViewMode = .parsed

    private enum ViewMode: String, CaseIterable {
        case parsed
        case raw
    }

    private var linksTo: [PageNode] {
        let targetEdges = model.activeGraph?.edges.filter { $0.source == node.id }.map(\.target) ?? []
        let targets = Set(targetEdges)
        return model.activeGraph?.nodes.filter { targets.contains($0.id) } ?? []
    }

    private var linkedFrom: [PageNode] {
        let sourceEdges = model.activeGraph?.edges.filter { $0.target == node.id }.map(\.source) ?? []
        let sources = Set(sourceEdges)
        return model.activeGraph?.nodes.filter { sources.contains($0.id) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatChip(label: "depth", value: "d\(node.depth)")
                StatChip(label: "chars", value: "\(node.chars)", tint: Theme.aqua)
                StatChip(label: "links out", value: "\(linksTo.count)", tint: Theme.teal)
                Spacer()
                Button {
                    if let url = URL(string: node.id) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("source", systemImage: "safari")
                }
                .buttonStyle(StitchedButtonStyle(prominent: false))
            }
            .padding(12)

            Text(node.id)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            HStack(spacing: 0) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        viewMode = mode
                    } label: {
                        Text(mode.rawValue)
                            .font(Theme.body(11))
                            .foregroundStyle(viewMode == mode ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .background(viewMode == mode ? Theme.cyan.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            Divider().overlay(Theme.panelBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let content = viewMode == .raw && !node.rawText.isEmpty ? node.rawText : node.excerpt
                    if content.isEmpty {
                        Text("no text compiled for this memory")
                            .font(Theme.body(12.5))
                            .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    } else {
                        Text(content)
                            .font(Theme.body(12.5))
                            .foregroundStyle(Theme.textPrimary.opacity(0.92))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !linksTo.isEmpty {
                        connectionSection(title: "links to", nodes: linksTo)
                    }
                    if !linkedFrom.isEmpty {
                        connectionSection(title: "linked from", nodes: linkedFrom)
                    }
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    private func connectionSection(title: String, nodes: [PageNode]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.display(14))
                .foregroundStyle(Theme.cyan)
                .shadow(color: Theme.cyan.opacity(0.4), radius: 5)
            ForEach(nodes.prefix(12)) { connected in
                Button {
                    model.selectNode(id: connected.id)
                } label: {
                    HStack(spacing: 6) {
                        Text("›")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.aqua.opacity(0.7))
                        Text(connected.title.lowercased())
                            .font(Theme.body(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .underline(false)
                    }
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
    }
}
