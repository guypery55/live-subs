import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private lazy var controller = SubtitleController(settings: settings)
    private var overlay: OverlayPanel?
    private var statusMenu: StatusMenu?
    private var hotKey: HotKey?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one copy at a time (e.g. opened by hand while it already runs from login).
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }

        let overlay = OverlayPanel(controller: controller, settings: settings)
        self.overlay = overlay
        controller.onNeedsSetup = { [weak self] in self?.showSetup() }
        statusMenu = StatusMenu(controller: controller, settings: settings, overlay: overlay,
                                openSetup: { [weak self] in self?.showSetup() })
        hotKey = HotKey { [weak self] in self?.controller.toggle() }

        // Subtitles start Off every time; only the setup window may appear on its own.
        if !settings.setupDone || KeyStore.load() == nil || !ScreenPermission.isGranted {
            showSetup()
        }
    }

    func showSetup() {
        if let window = setupWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SetupModel()
        let view = SetupView(model: model) { [weak self] in
            guard let self else { return }
            if !self.settings.setupDone {
                self.settings.setupDone = true
                LoginItem.setEnabled(true)
            }
            self.setupWindow?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "LiveSubs Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                model.stop()
                self?.setupWindow = nil
            }
        }
        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
