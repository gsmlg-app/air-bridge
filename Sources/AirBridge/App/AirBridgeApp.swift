import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
@MainActor
enum AirBridgeMain {
    private static var appDelegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let appState = AppState()
    private var statusController: StatusBarController?
    private var settingsWindow: NSWindow?
    private var settingsWindowController: NSWindowController?
    private var isOpeningSettings = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        installAppleEventHandlers()
        statusController = StatusBarController(appState: appState) { [weak self] in
            self?.openSettings()
        }
        openSettings()
        Log.server.info("AirBridge status item initialized")
    }

    func applicationWillTerminate(_ notification: Notification) {
        FileStaging.clearAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openSettings()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openSettings()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        openSettings()
    }

    private func openSettings() {
        guard !isOpeningSettings else { return }
        isOpeningSettings = true
        defer { isOpeningSettings = false }

        NSApp.setActivationPolicy(.regular)

        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(appState: appState))
            let window = NSWindow(contentViewController: controller)
            window.title = "AirBridge Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.canHide = false
            window.collectionBehavior = [.managed, .moveToActiveSpace]
            window.setContentSize(NSSize(width: 420, height: 520))
            settingsWindow = window
            settingsWindowController = NSWindowController(window: window)
        }

        guard let window = settingsWindow else { return }
        window.level = .normal
        window.center()
        window.deminiaturize(nil)
        window.setFrameAutosaveName("AirBridgeSettings")
        settingsWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installAppleEventHandlers() {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(
            self,
            andSelector: #selector(handleOpenOrReopenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
        manager.setEventHandler(
            self,
            andSelector: #selector(handleOpenOrReopenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
    }

    @objc private func handleOpenOrReopenEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        openSettings()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

@MainActor
private final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let openSettings: () -> Void

    init(appState: AppState, openSettings: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: 58)
        self.popover = NSPopover()
        self.openSettings = openSettings
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "AirBridge")
                ?? NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "AirBridge")
            button.imagePosition = .imageLeading
            button.title = "AB"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 260, height: 360)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(appState: appState, openSettingsAction: openSettings)
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
