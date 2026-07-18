import SwiftUI
import WebKit

@MainActor
final class TrunkBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var webView: WKWebView?
    var log: SystemLog?
    var onOpenNode: ((String) -> Void)?
    private var pendingGraphJSON: String?
    private var ready = false

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            if let json = pendingGraphJSON {
                pendingGraphJSON = nil
                inject(json)
            }
            log?.post(.info, "trunk", "memory trunk renderer online")
        case "open":
            if let id = body["id"] as? String {
                onOpenNode?(id)
            }
        case "log":
            let level = LogLevel(rawValue: body["level"] as? String ?? "info") ?? .info
            log?.post(level, "trunk", body["message"] as? String ?? "")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log?.post(.error, "trunk", "renderer failed to load: \(error.localizedDescription)")
    }

    func push(nodes: [PageNode], edges: [GraphEdge]) {
        struct TrunkNode: Encodable {
            let id: String
            let title: String
            let depth: Int
            let chars: Int
            let host: String
            let order: Int
        }
        struct TrunkEdge: Encodable {
            let source: String
            let target: String
        }
        struct TrunkGraph: Encodable {
            let nodes: [TrunkNode]
            let edges: [TrunkEdge]
        }
        let graph = TrunkGraph(
            nodes: nodes.enumerated().map { index, node in
                TrunkNode(
                    id: node.id,
                    title: node.title.lowercased(),
                    depth: node.depth,
                    chars: node.chars,
                    host: URL(string: node.id)?.host ?? "",
                    order: index
                )
            },
            edges: edges.map { TrunkEdge(source: $0.source, target: $0.target) }
        )
        guard let data = try? JSONEncoder().encode(graph),
              let json = String(data: data, encoding: .utf8) else {
            log?.post(.error, "trunk", "graph serialisation failed")
            return
        }
        if ready {
            inject(json)
        } else {
            pendingGraphJSON = json
        }
    }

    private func inject(_ json: String) {
        webView?.evaluateJavaScript("window.setGraph && window.setGraph(\(json));") { [weak self] _, error in
            if let error {
                self?.log?.post(.error, "trunk", "graph injection failed: \(error.localizedDescription)")
            }
        }
    }
}

struct TrunkWebView: NSViewRepresentable {
    let bridge: TrunkBridge

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(bridge, name: "trunk")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = bridge
        webView.setValue(false, forKey: "drawsBackground")
        bridge.webView = webView

        if let html = Bundle.module.url(forResource: "trunk", withExtension: "html") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            bridge.log?.post(.error, "trunk", "trunk.html missing from bundle — renderer unavailable")
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct TrunkPanel: View {
    @ObservedObject var model: AppModel
    @StateObject private var bridge = TrunkBridge()
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.exportMarkdown()
                } label: {
                    Label("export .md", systemImage: "doc.text")
                }
                .buttonStyle(StitchedButtonStyle(prominent: false))

                Button {
                    model.exportToObsidian()
                } label: {
                    Label("open in obsidian", systemImage: "circle.hexagongrid")
                }
                .buttonStyle(StitchedButtonStyle(prominent: true))

                Spacer()

                Text("drag to spin · spin to ascend")
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(Theme.panelBorder)

            TrunkWebView(bridge: bridge)
        }
        .buttonStyle(.plain)
        .onAppear {
            bridge.log = model.log
            bridge.onOpenNode = { id in model.selectNode(id: id) }
            schedulePush()
        }
        .onChange(of: model.activeGraph?.nodes.count ?? 0) { _, _ in schedulePush() }
        .onChange(of: model.isCrawling) { _, _ in
            if !model.isCrawling { schedulePush(delay: 0.1) }
        }
    }

    private func schedulePush(delay: TimeInterval = 0.8) {
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let graph = model.activeGraph else { return }
            bridge.push(nodes: graph.nodes, edges: graph.edges)
        }
    }
}
