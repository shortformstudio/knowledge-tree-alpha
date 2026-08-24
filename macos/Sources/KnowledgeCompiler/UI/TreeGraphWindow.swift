import AppKit
import SwiftUI

final class TreeGraphWindow: NSWindow {
    private var windowDelegate: WindowDelegate?

    init(model: AppModel) {
        super.init(
            contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "knowledge tree"
        isReleasedWhenClosed = true
        titlebarAppearsTransparent = true
        backgroundColor = NSColor(red: 0.012, green: 0.06, blue: 0.06, alpha: 1)
        isMovableByWindowBackground = true
        minSize = NSSize(width: 500, height: 400)

        let hosting = NSHostingView(
            rootView: TreeGraphContent(model: model)
        )
        contentView = hosting
    }

    func setCloseHandler(_ handler: @escaping () -> Void) {
        let d = WindowDelegate(onClose: handler)
        windowDelegate = d
        delegate = d
    }
}

struct TreeGraphContent: View {
    @ObservedObject var model: AppModel

    @State private var showForest = false

    private var graph: GraphStore {
        model.activeGraph ?? GraphStore()
    }

    var body: some View {
        ZStack {
            TrunkPanel(model: model, onForestToggle: { isForest in
                showForest = isForest
            })
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            showForest.toggle()
                        } label: {
                            Label(showForest ? "graph" : "forest", systemImage: showForest ? "point.3.connected.trianglepath.dotted" : "tree")
                                .font(Theme.body(11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.cyan.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()

                HStack {
                    Spacer()
                    Text("\(graph.nodeCount) nodes · \(graph.edgeCount) edges")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Window delegate helper

private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
