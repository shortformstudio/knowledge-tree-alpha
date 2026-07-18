import SwiftUI

struct GraphPanel: View {
    @ObservedObject var graph: GraphStore

    var body: some View {
        VStack(spacing: 0) {
            RingViz(nodes: graph.nodes, edges: graph.edges)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .padding(.top, 4)

            Divider().overlay(Theme.panelBorder)

            if graph.nodes.isEmpty {
                VStack(spacing: 6) {
                    Text("no knowledge compiled yet")
                        .font(Theme.display(16))
                        .foregroundStyle(Theme.textSecondary)
                    Text("run a compile to populate the graph")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(graph.nodes) { node in
                            NodeRow(node: node)
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

private struct NodeRow: View {
    let node: PageNode
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("d\(node.depth)")
                .font(Theme.mono(10))
                .foregroundStyle(depthColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(depthColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title.lowercased())
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(node.id)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textSecondary.opacity(hovering ? 1 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(node.chars)c")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.white.opacity(0.04) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private var depthColor: Color {
        switch node.depth {
        case 0: return Theme.cyan
        case 1: return Theme.aqua
        case 2: return Theme.teal
        default: return Theme.orange
        }
    }
}

private struct RingViz: View {
    let nodes: [PageNode]
    let edges: [GraphEdge]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxRadius = min(size.width, size.height) / 2 - 14
                let t = timeline.date.timeIntervalSinceReferenceDate

                for ring in 1...3 {
                    let r = maxRadius * CGFloat(ring) / 3
                    context.stroke(
                        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: .color(Theme.aqua.opacity(0.10)),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 5])
                    )
                }

                let sweepAngle = Angle.degrees((t * 24).truncatingRemainder(dividingBy: 360))
                let sweepEnd = CGPoint(
                    x: center.x + cos(sweepAngle.radians) * maxRadius,
                    y: center.y + sin(sweepAngle.radians) * maxRadius
                )
                var sweep = Path()
                sweep.move(to: center)
                sweep.addLine(to: sweepEnd)
                context.stroke(sweep, with: .color(Theme.cyan.opacity(0.18)), lineWidth: 1)

                var positions: [String: CGPoint] = [:]
                for node in nodes {
                    let radius = node.depth == 0 ? 0 : maxRadius * CGFloat(node.depth) / 3
                    let angle = Double(stableHash(node.id) % 3600) / 3600 * 2 * .pi
                    positions[node.id] = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )
                }

                for edge in edges {
                    guard let a = positions[edge.source], let b = positions[edge.target] else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(Theme.aqua.opacity(0.10)), lineWidth: 0.6)
                }

                for node in nodes {
                    guard let p = positions[node.id] else { continue }
                    let dotRadius: CGFloat = node.depth == 0 ? 5 : 3
                    let rect = CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    let color = node.depth == 0 ? Theme.cyan : Theme.aqua
                    context.fill(
                        Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                        with: .color(color.opacity(0.15))
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.9)))
                }
            }
        }
    }

    private func stableHash(_ text: String) -> Int {
        var hash = 5381
        for byte in text.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }
}
