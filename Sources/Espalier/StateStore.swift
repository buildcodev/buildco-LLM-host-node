#if os(macOS)
import AppKit
import EspalierCore

/// Files in `~/Library/Application Support/Espalier`: `config.json` (settings) and `tabs.json` (tab groups).
final class StateStore {
    let directory: URL
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var stateURL: URL { directory.appendingPathComponent("tabs.json") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = support.appendingPathComponent("Espalier", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads the config, writing a commented-by-example default the first time. A file that
    /// can't be read falls back to the defaults and reports why.
    func loadConfig() -> (Config, String?) {
        retireWindowManagerConfig()
        guard let data = try? Data(contentsOf: configURL) else {
            var example = Config()
            example.hotkeys = Config.defaultHotkeys
            if let data = try? example.encoded() { try? data.write(to: configURL, options: .atomic) }
            return (Config(), nil)
        }
        do {
            return (try Config.decode(data), nil)
        } catch {
            return (Config(), "config.json couldn't be read, so defaults are in use: \(error.localizedDescription)")
        }
    }

    /// The window-manager version of Espalier wrote its own settings here, with shortcuts
    /// (⌃⌥ and arrows) that clash with Grid's. They're kept aside, and fresh settings are written.
    private func retireWindowManagerConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["metrics"] != nil
        else { return }
        let kept = directory.appendingPathComponent("config.window-manager.json")
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.moveItem(at: configURL, to: kept)
        logger.info("Moved the window manager's settings to config.window-manager.json")
    }

    func loadSnapshot() -> TabsSnapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try TabsSnapshot.decode(data)
        } catch {
            logger.error("Couldn't read saved tab groups: \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file for inspection rather than overwriting it silently.
            let keep = directory.appendingPathComponent("tabs.unreadable.json")
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.moveItem(at: stateURL, to: keep)
            return nil
        }
    }

    func save(_ snapshot: TabsSnapshot) {
        do {
            try snapshot.encoded().write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Couldn't save tab groups: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
