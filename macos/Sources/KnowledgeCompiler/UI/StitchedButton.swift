import SwiftUI

struct StitchedButtonStyle: ButtonStyle {
    var prominent = true
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(13))
            .textCase(.lowercase)
            .foregroundStyle(prominent || active ? .white : Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if prominent || active {
                        LinearGradient(
                            colors: [Theme.teal.opacity(0.9), Theme.tealDark.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        LinearGradient(
                            colors: [.white.opacity(0.07), .white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        (prominent || active ? Color.white : Theme.aqua).opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.4, dash: [4, 3])
                    )
                    .padding(4)
            )
            .shadow(
                color: configuration.isPressed ? .clear : .black.opacity(0.35),
                radius: configuration.isPressed ? 2 : 5,
                y: configuration.isPressed ? 1 : 3
            )
            .shadow(color: active ? Theme.aqua.opacity(0.28) : .clear, radius: 8)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.25), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct StatChip: View {
    let label: String
    let value: String
    var tint: Color = Theme.cyan

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(Theme.display(22))
                .foregroundStyle(tint)
                .shadow(color: tint.opacity(0.5), radius: 6)
            Text(label)
                .font(Theme.body(10))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.aqua.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}
