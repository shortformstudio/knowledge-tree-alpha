import AppKit
import SwiftUI

struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct FabricBackground: View {
    var body: some View {
        ZStack {
            WindowBlur().ignoresSafeArea()

            RadialGradient(
                colors: [Theme.baseTeal.opacity(0.82), Theme.baseDeep.opacity(0.9)],
                center: .topLeading,
                startRadius: 40,
                endRadius: 1400
            )
            .ignoresSafeArea()

            Canvas { context, size in
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                        with: .color(.white.opacity(0.020))
                    )
                    x += 3
                }
                var y: CGFloat = 0
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.black.opacity(0.055))
                    )
                    y += 3
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            Circle()
                .fill(Theme.aqua)
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .opacity(0.10)
                .offset(x: -260, y: -220)
                .allowsHitTesting(false)
            Circle()
                .fill(Theme.cyan)
                .frame(width: 460, height: 460)
                .blur(radius: 120)
                .opacity(0.08)
                .offset(x: 340, y: 260)
                .allowsHitTesting(false)
        }
    }
}
