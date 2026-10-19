import Foundation

/// User settings, read from `~/Library/Application Support/Espalier/config.json`.
/// Any key can be left out to keep its default.
public struct Config: Codable, Equatable, Sendable {
    /// Command name to shortcut, such as `"next-tab": "ctrl+alt+]"`. Entries here are merged
    /// over the defaults; an empty string turns a default shortcut off.
    public var hotkeys: [String: String] = [:]
    /// Height of the tab strip above a group's window, in points.
    public var stripHeight: Double = 30
    /// The widest a single tab gets.
    public var maxTabWidth: Double = 280
    /// How long, in seconds, a dragged window has to hover over another window's title bar
    /// (or a tab strip) before letting go makes it a tab. Stops quick moves making tabs by accident.
    public var holdDelay: Double = 0.35
    /// How far down from the top of a window, in points, a dragged window can be let go to
    /// become a tab: the title bar and a margin below it. The drop outline shows this area.
    public var dropZoneHeight: Double = 80
    /// When a window snapped to half the screen needs more width than that, give its side
    /// the room and narrow the window on the other side.
    public var widenSides = true
    /// Apps whose windows are never put in tabs.
    public var excludedBundleIDs: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkeys = try c.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? d.hotkeys
        stripHeight = try c.decodeIfPresent(Double.self, forKey: .stripHeight) ?? d.stripHeight
        maxTabWidth = try c.decodeIfPresent(Double.self, forKey: .maxTabWidth) ?? d.maxTabWidth
        holdDelay = try c.decodeIfPresent(Double.self, forKey: .holdDelay) ?? d.holdDelay
        dropZoneHeight = try c.decodeIfPresent(Double.self, forKey: .dropZoneHeight) ?? d.dropZoneHeight
        widenSides = try c.decodeIfPresent(Bool.self, forKey: .widenSides) ?? d.widenSides
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
    }

    /// Shortcuts that stay clear of Grid's ⌃⌥ letters and arrows.
    public static let defaultHotkeys: [String: String] = [
        "next-tab": "ctrl+alt+]",
        "previous-tab": "ctrl+alt+[",
    ]

    /// The effective shortcut table: defaults overridden by the user's entries. Invalid
    /// entries are reported in `problems` and skipped.
    public func bindings() -> (bindings: [Hotkey: Command], problems: [String]) {
        var merged = Config.defaultHotkeys
        for (name, combo) in hotkeys { merged[name] = combo }
        var result: [Hotkey: Command] = [:]
        var problems: [String] = []
        for (name, combo) in merged.sorted(by: { $0.key < $1.key }) where !combo.isEmpty {
            guard let command = Command(name: name) else {
                problems.append("Unknown command \"\(name)\"")
                continue
            }
            guard let hotkey = Hotkey(combo) else {
                problems.append("Can't read shortcut \"\(combo)\" for \(name)")
                continue
            }
            if let existing = result[hotkey] {
                problems.append("\(combo) is bound to both \(existing.name) and \(name); keeping \(existing.name)")
                continue
            }
            result[hotkey] = command
        }
        return (result, problems)
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
