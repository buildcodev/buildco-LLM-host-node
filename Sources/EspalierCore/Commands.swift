import Foundation

/// Every action Espalier exposes. Each one has a URL (`espalier://next-tab`) and can be
/// bound to a hotkey by the same name (`"next-tab"`, `"tab/3"`).
public enum Command: Hashable, Sendable {
    /// Show the focused group's next tab.
    case nextTab
    case previousTab
    /// Show the focused group's tab at a position, from 1.
    case tab(Int)
    /// Take the focused window out of its group.
    case ungroup
    /// Take every window out of every group.
    case ungroupAll

    public static let scheme = "espalier"

    /// The command's name, as used in URLs and in the config file's hotkey table.
    public var name: String {
        switch self {
        case .nextTab: return "next-tab"
        case .previousTab: return "previous-tab"
        case .tab(let n): return "tab/\(n)"
        case .ungroup: return "ungroup"
        case .ungroupAll: return "ungroup-all"
        }
    }

    public var url: URL { URL(string: "\(Command.scheme)://\(name)")! }

    /// Parses a name such as `"next-tab"` or `"tab/3"`.
    public init?(name: String) {
        let parts = name.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return nil }
        self.init(head: head, argument: parts.count > 1 ? parts[1] : nil)
    }

    /// Parses `espalier://next-tab`, `espalier://tab/3` or `espalier://tab?n=3`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Command.scheme, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var argument = url.pathComponents.first { $0 != "/" }
        if argument == nil, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            argument = items.first { ["n", "tab", "index"].contains($0.name.lowercased()) }?.value
        }
        self.init(head: host, argument: argument?.lowercased())
    }

    private init?(head: String, argument: String?) {
        switch head {
        case "next-tab": self = .nextTab
        case "previous-tab": self = .previousTab
        case "ungroup": self = .ungroup
        case "ungroup-all": self = .ungroupAll
        case "tab":
            guard let n = argument.flatMap(Int.init), (1...9).contains(n) else { return nil }
            self = .tab(n)
        default:
            return nil
        }
    }

    /// Every command, for menus and documentation.
    public static var all: [Command] {
        [.nextTab, .previousTab, .ungroup, .ungroupAll] + (1...9).map(Command.tab)
    }
}

/// A global keyboard shortcut such as `ctrl+alt+up`.
public struct Hotkey: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// A normalised key name: a letter, a digit, an arrow (`up`), or a named key (`return`, `space`, `f5`, `[`).
    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let keyNames: Set<String> = {
        var names = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        names.formUnion(["up", "down", "left", "right", "return", "space", "tab", "escape", "delete",
                         "-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "`"])
        names.formUnion((1...20).map { "f\($0)" })
        return names
    }()

    private static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "backspace": "delete", "minus": "-", "equal": "=", "equals": "=",
        "leftbracket": "[", "rightbracket": "]", "semicolon": ";", "quote": "'", "comma": ",", "period": ".",
        "slash": "/", "backslash": "\\", "grave": "`", "arrowup": "up", "arrowdown": "down",
        "arrowleft": "left", "arrowright": "right",
    ]

    /// Parses strings such as `"ctrl+alt+up"`, `"cmd+shift+3"` or `"⌃⌥←"`.
    public init?(_ string: String) {
        var s = string.lowercased().replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        let symbols: [(String, String)] = [("⌘", "cmd+"), ("⌥", "alt+"), ("⌃", "ctrl+"), ("⇧", "shift+"),
                                           ("←", "left"), ("→", "right"), ("↑", "up"), ("↓", "down"), ("↩", "return")]
        for (symbol, word) in symbols { s = s.replacingOccurrences(of: symbol, with: word) }
        // A trailing "+" is the key itself only in "…++", which isn't a supported key; split normally.
        let parts = s.split(separator: "+").map(String.init)
        guard let last = parts.last else { return nil }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super": modifiers.insert(.command)
            case "alt", "opt", "option": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let key = Hotkey.aliases[last] ?? last
        guard Hotkey.keyNames.contains(key), !modifiers.isEmpty || key.hasPrefix("f") && key.count > 1 else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let symbols = ["up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↩", "space": "Space",
                       "tab": "⇥", "escape": "⎋", "delete": "⌫"]
        return s + (symbols[key] ?? key.uppercased())
    }
}
