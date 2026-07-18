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
        }
        .frame(width: 220)
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
