import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
            Snapshot.run(to: URL(fileURLWithPath: arguments[i + 1]))
        } else {
            UptickApp.main()
        }
    }
}

struct UptickApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Uptick", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 720, height: 640)
    }
}

/// `Uptick --snapshot out.png` checks this Mac, renders the window offscreen and exits.
/// Needs no screen-recording permission, so layout can be checked from a terminal.
@MainActor
enum Snapshot {
    static func run(to file: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = AppModel()
        Task {
            // UPTICK_SNAPSHOT_CHECKING=1 captures the window mid-check instead of after it.
            let midCheck = ProcessInfo.processInfo.environment["UPTICK_SNAPSHOT_CHECKING"] != nil
            if midCheck {
                await model.refresh()
                Task { await model.refresh() }
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else {
                await model.refresh()
            }
            let host = NSHostingView(rootView: ContentView().environment(model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: midCheck ? 100_000_000 : 1_000_000_000)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
            exit(0)
        }
        app.run()
    }
}
