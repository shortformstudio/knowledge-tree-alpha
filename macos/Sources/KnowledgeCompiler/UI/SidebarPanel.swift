import SwiftUI

struct SidebarPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("knowledge graphs")
                .font(Theme.body(10))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .overlay(Theme.panelBorder)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.graphManager.graphs) { graph in
                        GraphRow(
                            graph: graph,
                            isActive: model.graphManager.activeGraphID == graph.id,
                            onSelect: { model.activateGraph(id: graph.id) },
                            onDelete: {
                                if model.graphManager.graphs.count > 1 {
                                    model.deleteGraph(id: graph.id)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            Divider()
                .overlay(Theme.panelBorder)

            if model.graphManager.activeGraph != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("add url to crawl")
                        .font(Theme.body(9))
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        TextField("url", text: $model.urlText)
                            .textFieldStyle(.plain)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .disabled(model.isCrawling)

                        Button {
                            model.saveGraph()
                            model.startCrawl()
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.cyan)
                        .disabled(model.isCrawling || model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(10)
            }

            // ── Toolbar buttons ──────────────────────────────────────────
            Divider()
                .overlay(Theme.panelBorder)

            VStack(spacing: 2) {
                SidebarToolButton(
                    icon: "tree",
                    label: "tree graph",
                    help: "Open the 3D knowledge tree in a floating window",
                    action: { model.openTreeGraph() }
                )
                SidebarToolButton(
                    icon: "point.3.connected.trianglepath.dotted",
                    label: "obsidian graph",
                    help: "Export the compiled dataset to an Obsidian vault with Mermaid graph",
                    action: { model.exportToObsidian() }
                )
                SidebarToolButton(
                    icon: "line.3.horizontal.decrease",
                    label: "mission control",
                    help: "Toggle clutter filters and parsing options",
                    action: { model.showMissionControl.toggle() }
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(width: 220)
    }
}

// MARK: - Sidebar tool button

private struct SidebarToolButton: View {
    let icon: String
    let label: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(label)
                    .font(Theme.body(11))
                Spacer()
            }
            .foregroundStyle(isHovering ? Theme.cyan : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Theme.cyan.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            isHovering = inside
        }
    }
}

// MARK: - Graph row

private struct GraphRow: View {
    let graph: KnowledgeGraphMeta
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(graph.title.lowercased())
                    .font(Theme.body(11))
                    .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(graph.nodeCount) nodes")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    Text("·")
                        .foregroundStyle(Theme.textSecondary.opacity(0.4))
                    Text(graph.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
            }

            Spacer()

            if isHovering {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.orange.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.cyan.opacity(0.12) : .white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? Theme.aqua.opacity(0.35) : Theme.aqua.opacity(0.08),
                    lineWidth: isActive ? 1 : 0.5
                )
        )
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if isHovering { NSCursor.pop() }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onSelect()
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
    }
}
