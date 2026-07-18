import SwiftUI

struct PanelFrame: Equatable {
    var origin: CGPoint
    var size: CGSize
}

struct GlassPanel<Content: View>: View {
    let title: String
    @Binding var frame: PanelFrame
    var minSize = CGSize(width: 260, height: 160)
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var dragStart: CGPoint?
    @State private var resizeStart: CGSize?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .frame(width: frame.size.width, height: frame.size.height)
        .background(Theme.panelBG)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Theme.aqua.opacity(0.12), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .padding(6)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .shadow(color: hovering ? Theme.aqua.opacity(0.10) : .clear, radius: 22)
        .onHover { hovering = $0 }
        .position(x: frame.origin.x + frame.size.width / 2, y: frame.origin.y + frame.size.height / 2)
        .animation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.2), value: hovering)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.cyan)
                .frame(width: 5, height: 5)
                .shadow(color: Theme.cyan.opacity(0.9), radius: 4)
            Text(title)
                .font(Theme.display(17))
                .foregroundStyle(Theme.textPrimary)
                .shadow(color: Theme.aqua.opacity(0.35), radius: 6)
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .light))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(5)
                        .overlay(
                            Circle().strokeBorder(
                                Theme.aqua.opacity(hovering ? 0.4 : 0.15),
                                style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 9, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(hovering ? 0.8 : 0.3))
        }
        .textCase(.lowercase)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.03))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named("canvas"))
                .onChanged { value in
                    if dragStart == nil { dragStart = frame.origin }
                    guard let start = dragStart else { return }
                    frame.origin = CGPoint(
                        x: start.x + value.translation.width,
                        y: start.y + value.translation.height
                    )
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    private var resizeGrip: some View {
        Path { path in
            for i in 0..<3 {
                let inset = CGFloat(4 + i * 4)
                path.move(to: CGPoint(x: 16, y: 16 - inset))
                path.addLine(to: CGPoint(x: 16 - inset, y: 16))
            }
        }
        .stroke(Theme.aqua.opacity(hovering ? 0.55 : 0.25), lineWidth: 1)
        .frame(width: 16, height: 16)
        .padding(6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if resizeStart == nil { resizeStart = frame.size }
                    guard let start = resizeStart else { return }
                    frame.size = CGSize(
                        width: max(minSize.width, start.width + value.translation.width),
                        height: max(minSize.height, start.height + value.translation.height)
                    )
                }
                .onEnded { _ in resizeStart = nil }
        )
    }
}
