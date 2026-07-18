import SwiftUI

struct LogPanel: View {
    @ObservedObject var log: SystemLog

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(log.entries) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.timeFormatter.string(from: entry.time))
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.5))
                                Text(entry.level.glyph)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(entry.level.color)
                                    .shadow(color: entry.level.color.opacity(0.7), radius: 3)
                                    .frame(width: 10)
                                Text(entry.source)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.teal.opacity(0.8))
                                    .frame(width: 52, alignment: .leading)
                                Text(entry.message)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(
                                        entry.level == .error
                                            ? entry.level.color
                                            : Theme.textPrimary.opacity(0.85)
                                    )
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: log.entries.count) {
                    if let last = log.entries.last {
                        withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.3)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider().overlay(Theme.panelBorder)

            HStack {
                Text("\(log.entries.count) events")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
                Spacer()
                Button("clear") { log.clear() }
                    .buttonStyle(.plain)
                    .font(Theme.body(10))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }
}
