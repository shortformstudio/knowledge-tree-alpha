import AppKit
import SwiftUI

struct KnowledgeCompilerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 920)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first {
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .clear
            window.isOpaque = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
enum Main {
    static func main() async {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--selftest") {
            let url = args.count > index + 1 ? args[index + 1] : "https://opencode.ai/docs"
            let depth = args.count > index + 2 ? Int(args[index + 2]) ?? 1 : 1
            let passed = await SelfTest.run(startURL: url, depth: depth)
            exit(passed ? 0 : 1)
        }
        KnowledgeCompilerApp.main()
    }
}
