#if os(macOS)
import AppKit
import EspalierCore

/// Files in `~/Library/Application Support/Espalier`: `config.json` (settings) and `state.json` (layouts).
final class StateStore {
    let directory: URL
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = support.appendingPathComponent("Espalier", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads the config, writing a commented-by-example default the first time. A file that
    /// can't be read falls back to the defaults and reports why.
    func loadConfig() -> (Config, String?) {
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

    func loadSnapshot() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try WorkspaceSnapshot.decode(data)
        } catch {
            logger.error("Couldn't read saved layouts: \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file for inspection rather than overwriting it silently.
            try? FileManager.default.moveItem(at: stateURL, to: directory.appendingPathComponent("state.unreadable.json"))
            return nil
        }
    }

    func save(_ snapshot: WorkspaceSnapshot) {
        do {
            try snapshot.encoded().write(to: stateURL, options: .atomic)
        } catch {
            logger.error("Couldn't save layouts: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
