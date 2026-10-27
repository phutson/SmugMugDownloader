import AppKit
import SwiftUI

@main
struct SmugMugDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("SmugMug Downloader", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 640)
        }
        .defaultSize(width: 700, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` so the app gets a Dock icon and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
