import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    @State private var controlFrame = PanelFrame(
        origin: CGPoint(x: 250, y: 80),
        size: CGSize(width: 420, height: 260)
    )
    @State private var logFrame = PanelFrame(
        origin: CGPoint(x: 250, y: 600),
        size: CGSize(width: 640, height: 150)
    )
    @State private var scraperFrame = PanelFrame(
        origin: CGPoint(x: 910, y: 80),
        size: CGSize(width: 420, height: 420)
    )
    @State private var readerFrame = PanelFrame(
        origin: CGPoint(x: 910, y: 80),
        size: CGSize(width: 480, height: 520)
    )

    private var showForest: Bool {
        guard let g = model.activeGraph else { return true }
        return g.nodeCount == 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            FabricBackground()

            CylinderVisualizer(
                graph: model.activeGraph ?? GraphStore(),
                onSelectNode: { nodeID in
                    model.selectNode(id: nodeID)
                    if let node = model.selectedNode {
                        model.openFloatingReader(for: node)
                    }
                },
                forestTrees: model.forestTreeEntries,
                forestMode: showForest,
                onSelectForestTree: { id in
                    model.activateGraph(id: id)
                }
            )
            .ignoresSafeArea()

            TopBar(model: model)

            SidebarPanel(model: model)
                .padding(.top, 44)

            if model.activeGraph != nil {
                GlassPanel(title: "mission control", frame: $controlFrame, minSize: CGSize(width: 360, height: 220)) {
                    ControlPanel(model: model)
                }

                GlassPanel(title: "system log", frame: $logFrame, minSize: CGSize(width: 420, height: 120)) {
                    LogPanel(log: model.log)
                }

                GlassPanel(title: "profile scraper", frame: $scraperFrame, minSize: CGSize(width: 380, height: 340)) {
                    ProfileScraperPanel(model: model)
                }

                if let node = model.selectedNode {
                    GlassPanel(
                        title: node.title.lowercased(),
                        frame: $readerFrame,
                        minSize: CGSize(width: 320, height: 260),
                        onClose: { model.closeReader() }
                    ) {
                        NodeReaderPanel(model: model, node: node)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .coordinateSpace(name: "canvas")
        .frame(minWidth: 1100, minHeight: 780)
        .preferredColorScheme(.dark)
        .animation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.3), value: model.selectedNodeID)
    }
}
