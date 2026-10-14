import Foundation

/// User settings, read from `~/Library/Application Support/Espalier/config.json`.
/// Any key can be left out to keep its default.
public struct Config: Codable, Equatable, Sendable {
    public var metrics = LayoutMetrics()
    /// Command name to shortcut, such as `"zoom-out": "ctrl+alt+up"`. Entries here are merged
    /// over the defaults; an empty string turns a default shortcut off.
    public var hotkeys: [String: String] = [:]
    /// Dragging a window onto an edge docks it.
    public var docking = true
    /// Hold this modifier while releasing a dragged window to keep it floating.
    public var keepFloatingModifier = "shift"
    /// Pinching while holding this modifier zooms the layout. Pinching over bare desktop always does.
    public var pinchModifier = "alt"
    public var gestures = true
    /// How much pinch (in magnification units) steps the camera one level.
    public var pinchStep = 0.2
    /// Length of the camera animation, in seconds. 0 turns animation off.
    public var animationDuration = 0.28
    /// Apps whose windows are never managed.
    public var excludedBundleIDs: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        metrics = try c.decodeIfPresent(LayoutMetrics.self, forKey: .metrics) ?? d.metrics
        hotkeys = try c.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? d.hotkeys
        docking = try c.decodeIfPresent(Bool.self, forKey: .docking) ?? d.docking
        keepFloatingModifier = try c.decodeIfPresent(String.self, forKey: .keepFloatingModifier) ?? d.keepFloatingModifier
        pinchModifier = try c.decodeIfPresent(String.self, forKey: .pinchModifier) ?? d.pinchModifier
        gestures = try c.decodeIfPresent(Bool.self, forKey: .gestures) ?? d.gestures
        pinchStep = try c.decodeIfPresent(Double.self, forKey: .pinchStep) ?? d.pinchStep
        animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? d.animationDuration
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? d.excludedBundleIDs
    }

    public static let defaultHotkeys: [String: String] = {
        var keys: [String: String] = [
            "zoom-out": "ctrl+alt+up",
            "zoom-in": "ctrl+alt+down",
            "back": "ctrl+alt+left",
            "forward": "ctrl+alt+right",
            "overview": "ctrl+alt+o",
            "maximize": "ctrl+alt+return",
            "toggle-float": "ctrl+alt+f",
            "arrange": "ctrl+alt+a",
            "relayout": "ctrl+alt+r",
            "next-tab": "ctrl+alt+]",
            "previous-tab": "ctrl+alt+[",
            "focus/left": "ctrl+alt+cmd+left",
            "focus/right": "ctrl+alt+cmd+right",
            "focus/top": "ctrl+alt+cmd+up",
            "focus/bottom": "ctrl+alt+cmd+down",
        ]
        for n in 1...9 {
            keys["view/\(n)"] = "ctrl+alt+\(n)"
            keys["save-view/\(n)"] = "ctrl+alt+shift+\(n)"
        }
        return keys
    }()

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
