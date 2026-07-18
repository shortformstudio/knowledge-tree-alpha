import SwiftUI

struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("https://target.site", text: $model.urlText)
                .textFieldStyle(.plain)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.aqua.opacity(0.18), lineWidth: 1)
                )
                .onSubmit { model.startCrawl() }
                .disabled(model.isCrawling)

            HStack(spacing: 10) {
                Text("links deep")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(1...3, id: \.self) { d in
                    Button("\(d)") { model.depth = d }
                        .buttonStyle(StitchedButtonStyle(prominent: false, active: model.depth == d))
                        .disabled(model.isCrawling)
                }
                Spacer()
                Toggle(isOn: $model.sameDomainOnly) {
                    Text("same domain")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.teal)
                .disabled(model.isCrawling)
            }

            HStack(spacing: 12) {
                if model.isCrawling {
                    Button {
                        model.stopCrawl()
                    } label: {
                        Label("stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: false))

                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.cyan)
                } else {
                    Button {
                        model.startCrawl()
                    } label: {
                        Label("compile knowledge", systemImage: "sparkles")
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: true))
                }
                Spacer()
            }

            HStack(spacing: 10) {
                StatChip(label: "pages", value: "\(model.activeGraph?.nodeCount ?? 0)")
                StatChip(label: "edges", value: "\(model.activeGraph?.edgeCount ?? 0)", tint: Theme.aqua)
                StatChip(
                    label: "errors",
                    value: "\(model.lastSummary?.errors ?? 0)",
                    tint: (model.lastSummary?.errors ?? 0) > 0 ? Theme.orange : Theme.green
                )
                if let summary = model.lastSummary {
                    StatChip(label: "seconds", value: String(format: "%.1f", summary.duration), tint: Theme.textSecondary)
                }
            }
        }
        .padding(14)
        .buttonStyle(.plain)
    }
}
