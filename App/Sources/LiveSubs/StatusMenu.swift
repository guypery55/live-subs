import AppKit
import Combine

/// The menu-bar icon and its menu. The icon is filled while subtitles are on.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: SubtitleController
    private let settings: Settings
    private let overlay: OverlayPanel
    private let openSetup: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(controller: SubtitleController, settings: Settings, overlay: OverlayPanel,
         openSetup: @escaping () -> Void) {
        self.controller = controller
        self.settings = settings
        self.overlay = overlay
        self.openSetup = openSetup
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        controller.$isOn.combineLatest(controller.$problem)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let name: String
        if let problem = controller.problem, !problem.isRetryable {
            name = "exclamationmark.bubble"
        } else {
            name = controller.isOn ? "captions.bubble.fill" : "captions.bubble"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "LiveSubs")
            ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "LiveSubs")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = controller.statusLine
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let toggle = NSMenuItem(title: controller.isOn ? "Turn Subtitles Off" : "Turn Subtitles On",
                                action: #selector(toggleSubtitles), keyEquivalent: "s")
        toggle.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(target(toggle))
        menu.addItem(.separator())

        let hebrew = NSMenuItem(title: "Also Show Hebrew", action: #selector(toggleHebrew), keyEquivalent: "")
        hebrew.state = settings.showHebrew ? .on : .off
        menu.addItem(target(hebrew))
        menu.addItem(target(NSMenuItem(title: "Bigger Text", action: #selector(bigger), keyEquivalent: "")))
        menu.addItem(target(NSMenuItem(title: "Smaller Text", action: #selector(smaller), keyEquivalent: "")))
        menu.addItem(target(NSMenuItem(title: "Move Subtitles…", action: #selector(move), keyEquivalent: "")))
        menu.addItem(.separator())

        menu.addItem(target(NSMenuItem(title: "Setup…", action: #selector(setup), keyEquivalent: "")))
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(target(login))
        menu.addItem(target(NSMenuItem(title: "Quit LiveSubs", action: #selector(quit), keyEquivalent: "q")))
    }

    private func target(_ menuItem: NSMenuItem) -> NSMenuItem {
        menuItem.target = self
        return menuItem
    }

    @objc private func toggleSubtitles() { controller.toggle() }
    @objc private func toggleHebrew() { settings.showHebrew.toggle() }
    @objc private func bigger() { settings.biggerText() }
    @objc private func smaller() { settings.smallerText() }
    @objc private func move() { overlay.startMoving() }
    @objc private func setup() { openSetup() }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func quit() { NSApp.terminate(nil) }
}
