#if os(macOS)
import AppKit
import EspalierCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = StateStore()
    private var manager: WindowManager!
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = WindowManager(store: store)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x1.below.line.grid.1x2", accessibilityDescription: "Espalier")
            ?? NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Espalier")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        if AX.isTrusted {
            manager.start()
        } else {
            AX.requestTrust()
            // Start as soon as the permission is granted in System Settings.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard AX.isTrusted else { return }
                timer.invalidate()
                self?.manager.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
    }

    /// `espalier://…` URLs, from `open`, Raycast, Alfred, Shortcuts or a Stream Deck.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = Command(url: url) else {
                logger.warning("Unknown command URL: \(url.absoluteString, privacy: .public)")
                continue
            }
            manager?.perform(command)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcuts = manager.shortcuts

        if !AX.isTrusted {
            menu.addItem(item("Grant Accessibility Permission…", #selector(grantAccessibility)))
            menu.addItem(note("Espalier needs Accessibility access to move windows."))
            menu.addItem(.separator())
        }

        let navigation: [(String, Command)] = [
            ("Zoom Out", .zoomOut), ("Zoom In", .zoomIn), ("Overview", .overview),
            ("Back", .back), ("Forward", .forward), ("Fill Screen with Window", .maximize),
        ]
        for (title, command) in navigation { menu.addItem(commandItem(title, command, shortcuts)) }
        menu.addItem(.separator())
        let arranging: [(String, Command)] = [
            ("Arrange Floating Windows", .arrange), ("Dock or Float Window", .toggleFloat),
            ("Next Tab", .nextTab), ("Previous Tab", .previousTab), ("Put Windows Back", .relayout),
        ]
        for (title, command) in arranging { menu.addItem(commandItem(title, command, shortcuts)) }

        let views = NSMenu()
        views.autoenablesItems = false
        let saved = manager.savedViews
        for slot in 1...9 {
            let go = commandItem("Go to View \(slot)", .view(slot), shortcuts)
            go.isEnabled = saved.contains(slot)
            views.addItem(go)
        }
        views.addItem(.separator())
        for slot in 1...9 { views.addItem(commandItem("Save Current View as \(slot)", .saveView(slot), shortcuts)) }
        let viewsItem = NSMenuItem(title: "Saved Views", action: nil, keyEquivalent: "")
        viewsItem.submenu = views
        menu.addItem(viewsItem)

        menu.addItem(.separator())
        if !manager.snapshotter.isAuthorized {
            menu.addItem(item("Show Window Contents While Zooming…", #selector(grantScreenRecording)))
        }
        menu.addItem(item("Open Settings File", #selector(openConfig)))
        menu.addItem(item("Reload Settings", #selector(reloadConfig)))
        menu.addItem(item("Reset This Display's Layout", #selector(resetLayout)))
        for problem in manager.problems.prefix(5) { menu.addItem(note("⚠︎ " + problem)) }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Espalier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func commandItem(_ title: String, _ command: Command, _ shortcuts: [Command: Hotkey]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.name
        item.isEnabled = manager.started
        if let hotkey = shortcuts[command] {
            let (key, modifiers) = hotkey.menuEquivalent
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let command = Command(name: name) else { return }
        manager.perform(command)
    }

    @objc private func grantAccessibility() {
        AX.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func grantScreenRecording() {
        manager.snapshotter.requestAccess()
    }

    @objc private func openConfig() {
        _ = store.loadConfig()
        NSWorkspace.shared.open(store.configURL)
    }

    @objc private func reloadConfig() {
        manager.reloadConfig()
    }

    @objc private func resetLayout() {
        manager.resetActiveDisplay()
    }
}
#endif
