import AppKit
import SwiftUI

final class FloatingReaderWindow: NSWindow {
    init(node: PageNode, graphTitle: String) {
        super.init(
            contentRect: NSRect(x: 400, y: 300, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "\(node.title.lowercased()) · \(graphTitle)"
        isReleasedWhenClosed = true
        titlebarAppearsTransparent = true
        backgroundColor = NSColor(red: 0.012, green: 0.06, blue: 0.06, alpha: 1)
        isMovableByWindowBackground = true
        minSize = NSSize(width: 340, height: 260)

        let hosting = NSHostingView(
            rootView: FloatingReaderContent(node: node, graphTitle: graphTitle)
        )
        contentView = hosting
    }
}

struct FloatingReaderContent: View {
    let node: PageNode
    let graphTitle: String

    @State private var fontSize: CGFloat = 14
    @State private var viewMode: ViewMode = .parsed

    private enum ViewMode: String, CaseIterable {
        case parsed
        case raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(graphTitle)
                    .font(Theme.display(16))
                    .foregroundStyle(Theme.cyan)
                    .shadow(color: Theme.cyan.opacity(0.3), radius: 4)

                Spacer()

                HStack(spacing: 2) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { viewMode = mode }
                            .buttonStyle(.plain)
                            .font(Theme.body(10))
                            .foregroundStyle(viewMode == mode ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(viewMode == mode ? Theme.cyan.opacity(0.15) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                HStack(spacing: 4) {
                    Button { fontSize = max(10, fontSize - 2) } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    Button { fontSize = min(32, fontSize + 2) } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                }

                Button {
                    if let url = URL(string: node.id) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.aqua)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)

            Text(node.id)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            Divider()
                .overlay(Theme.panelBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let content = viewMode == .raw && !node.rawText.isEmpty ? node.rawText : node.excerpt
                    if content.isEmpty {
                        Text("_no text compiled_")
                            .font(.system(size: fontSize))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(content)
                            .font(.system(size: fontSize))
                            .foregroundStyle(Theme.textPrimary.opacity(0.92))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.baseDeep.opacity(0.96))
        .preferredColorScheme(.dark)
    }
}
