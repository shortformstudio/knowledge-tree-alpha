import SwiftUI

struct TopBar: View {
    @ObservedObject var model: AppModel

    @State private var showNewGraphSheet = false
    @State private var newGraphTitle = ""
    @State private var dragStartFrame: NSRect? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text("knowledge compiler")
                .glowTitle(28, rotation: -0.8)
                .padding(.leading, 4)

            Spacer()

            Button {
                model.saveGraph()
            } label: {
                Label("save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(StitchedButtonStyle(prominent: false))
            .disabled(
                model.graphManager.activeGraph == nil
                || model.graphManager.activeGraph?.nodeCount == 0
                || model.isCrawling
            )

            Button {
                model.exportToObsidian()
            } label: {
                Label("obsidian", systemImage: "circle.hexagongrid")
            }
            .buttonStyle(StitchedButtonStyle(prominent: true))
            .disabled(
                model.graphManager.activeGraph == nil
                || model.graphManager.activeGraph?.nodeCount == 0
            )

            Button {
                showNewGraphSheet = true
            } label: {
                Label("new", systemImage: "plus")
            }
            .buttonStyle(StitchedButtonStyle(prominent: true))
            .disabled(model.isCrawling || model.isScraping)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.clear)
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard let window = NSApp.keyWindow else { return }
                    if dragStartFrame == nil { dragStartFrame = window.frame }
                    guard let start = dragStartFrame else { return }
                    var frame = start
                    frame.origin.x += value.translation.width
                    frame.origin.y -= value.translation.height
                    window.setFrame(frame, display: true)
                }
                .onEnded { _ in dragStartFrame = nil }
        )
        .sheet(isPresented: $showNewGraphSheet) {
            VStack(spacing: 16) {
                Text("new knowledge graph")
                    .font(Theme.display(22))
                    .foregroundStyle(Theme.textPrimary)

                TextField("graph title", text: $newGraphTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.aqua.opacity(0.25), lineWidth: 1)
                    )
                    .frame(width: 300)
                    .onSubmit {
                        commitNewGraph()
                    }

                HStack(spacing: 12) {
                    Button("cancel") {
                        showNewGraphSheet = false
                        newGraphTitle = ""
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: false))

                    Button("create") {
                        commitNewGraph()
                    }
                    .buttonStyle(StitchedButtonStyle(prominent: true))
                    .disabled(newGraphTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(30)
            .frame(width: 380, height: 200)
            .background(Theme.baseDeep.opacity(0.95))
            .preferredColorScheme(.dark)
        }
    }

    private func commitNewGraph() {
        let title = newGraphTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        model.newGraph(title: title)
        showNewGraphSheet = false
        newGraphTitle = ""
    }
}
