import SwiftUI
import AppKit

@main
struct R2ManApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("R2 Desk", id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
                .tint(.orange)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.duplicateTab() }.keyboardShortcut("t").disabled(model.current == nil)
                Button("Add R2 Connection…") { model.addConnection() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Close Tab") { if let tab = model.current { model.closeTab(tab) } }.keyboardShortcut("w")
                    .disabled(model.tabs.count < 2)
            }
            CommandMenu("Files") {
                Button("Upload…") { model.chooseUpload() }.keyboardShortcut("u").disabled(model.busy || model.current?.bucket == nil)
                Button("Download…") { model.downloadSelection() }.keyboardShortcut("d")
                    .disabled(model.busy || model.current?.selectedItems.isEmpty != false)
                Divider()
                Button("Refresh") { model.reload() }.keyboardShortcut("r").disabled(model.current == nil)
                Button("Go Up") { model.goUp() }.keyboardShortcut(.upArrow).disabled(model.current?.location.parent == nil)
                Button("Go Back") { model.goBack() }.keyboardShortcut("[").disabled(model.current?.canGoBack != true)
                Button("Go Forward") { model.goForward() }.keyboardShortcut("]").disabled(model.current?.canGoForward != true)
                Divider()
                Button("Delete…") { model.deleteSelection() }.keyboardShortcut(.delete)
                    .disabled(model.busy || model.current?.selectedItems.isEmpty != false)
                Button("Transfers") { model.showTransfers.toggle() }.keyboardShortcut("j")
            }
        }
    }
}

enum AppIcon {
    static var image: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppIcon.image {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // File writes use temporary files. URLSession stops when this process ends.
        return .terminateNow
    }
}
