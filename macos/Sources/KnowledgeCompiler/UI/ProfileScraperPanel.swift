import SwiftUI

struct ProfileScraperPanel: View {
    @ObservedObject var model: AppModel

    @State private var profileURL = ""
    @State private var savedFiles: [(url: URL, date: Date, handle: String, platform: String)] = []
    @State private var threadsLoggedIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(threadsLoggedIn ? Theme.green : Theme.orange)
                    .frame(width: 7, height: 7)
                Text(threadsLoggedIn ? "threads session active" : "threads login required")
                    .font(Theme.body(10))
                    .foregroundStyle(threadsLoggedIn ? Theme.green : Theme.orange)

                Spacer()

                if !threadsLoggedIn {
                    Button {
                        model.openThreadsLogin()
                    } label: {
                        Text("login")
                            .font(Theme.body(10))
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: true))
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                TextField("https://threads.net/@handle", text: $profileURL)
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
                    .disabled(model.isScraping)
                    .onSubmit { model.startProfileScrape(url: profileURL) }

                Button {
                    model.startProfileScrape(url: profileURL)
                } label: {
                    Label("scrape", systemImage: "person.text.rectangle")
                }
                .buttonStyle(StitchedButtonStyle(prominent: true))
                .disabled(model.isScraping || profileURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.isScraping {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.cyan)
                    Text("scraping profile…")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        model.cancelProfileScrape()
                    } label: {
                        Label("stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: false))
                }
            }

            if let last = model.lastScrapeResult {
                HStack(spacing: 10) {
                    StatChip(label: "posts", value: "\(last.postCount)")
                    StatChip(label: "platform", value: last.platform, tint: Theme.aqua)
                    Button {
                        NSWorkspace.shared.open(last.mdURL)
                    } label: {
                        Label("open .md", systemImage: "doc.text")
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: true))
                }
                .padding(.top, 4)
            }

            Divider()
                .overlay(Theme.panelBorder)

            Text("saved profile scrapes")
                .font(Theme.body(11))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(savedFiles, id: \.url) { file in
                        SavedScrapeRow(
                            handle: file.handle,
                            platform: file.platform,
                            date: file.date,
                            onClick: { NSWorkspace.shared.open(file.url) },
                            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        )
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .onAppear {
            refreshSavedFiles()
            checkThreadsSession()
        }
        .onChange(of: model.lastScrapeResult?.mdURL.absoluteString) { _, _ in
            refreshSavedFiles()
            checkThreadsSession()
        }
    }

    private func checkThreadsSession() {
        Task { @MainActor in
            threadsLoggedIn = await ProfileScraper.hasThreadsCookies()
        }
    }

    private func refreshSavedFiles() {
        savedFiles = ProfileScraper.listSavedScrapes()
    }
}

// MARK: - Saved scrape row

private struct SavedScrapeRow: View {
    let handle: String
    let platform: String
    let date: Date
    let onClick: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Theme.cyan)

            VStack(alignment: .leading, spacing: 1) {
                Text("@\(handle)")
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(platform) · \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                onReveal()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
    }
}
