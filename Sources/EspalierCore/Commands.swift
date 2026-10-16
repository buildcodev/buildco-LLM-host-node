import Foundation

/// Every action Espalier exposes. Each one has a URL (`espalier://zoom-out`) and can
/// be bound to a hotkey by the same name (`"zoom-out"`, `"view/3"`).
public enum Command: Hashable, Sendable {
    /// Dock every floating window on the display into the layout.
    case arrange
    /// Put every window back in its slot.
    case relayout
    case back
    case forward
    case zoomOut
    case zoomIn
    case overview
    /// Fill the screen with the focused window's slot, or go back.
    case maximize
    /// Dock the focused window beside the desktop, or float it.
    case toggleFloat
    case focus(Edge)
    /// Dock the focused window against an edge of the screen.
    case dock(Edge)
    case view(Int)
    case saveView(Int)
    case nextTab
    case previousTab

    public static let scheme = "espalier"

    /// The command's name, as used in URLs and in the config file's hotkey table.
    public var name: String {
        switch self {
        case .arrange: return "arrange"
        case .relayout: return "relayout"
        case .back: return "back"
        case .forward: return "forward"
        case .zoomOut: return "zoom-out"
        case .zoomIn: return "zoom-in"
        case .overview: return "overview"
        case .maximize: return "maximize"
        case .toggleFloat: return "toggle-float"
        case .focus(let e): return "focus/\(e.rawValue)"
        case .dock(let e): return "dock/\(e.rawValue)"
        case .view(let n): return "view/\(n)"
        case .saveView(let n): return "save-view/\(n)"
        case .nextTab: return "next-tab"
        case .previousTab: return "previous-tab"
        }
    }

    public var url: URL { URL(string: "\(Command.scheme)://\(name)")! }

    /// Parses a name such as `"zoom-out"` or `"view/3"`.
    public init?(name: String) {
        let parts = name.lowercased().split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let head = parts.first else { return nil }
        self.init(head: head, argument: parts.count > 1 ? parts[1] : nil)
    }

    /// Parses `espalier://zoom-out`, `espalier://view/3`, `espalier://view?n=3` or `espalier://focus?direction=left`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Command.scheme, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        var argument = url.pathComponents.first { $0 != "/" }
        if argument == nil, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            argument = items.first { ["n", "slot", "view", "direction", "edge"].contains($0.name.lowercased()) }?.value
        }
        self.init(head: host, argument: argument?.lowercased())
    }

    private init?(head: String, argument: String?) {
        let slot = argument.flatMap(Int.init).flatMap { (1...9).contains($0) ? $0 : nil }
        let edge = argument.flatMap(Edge.init(rawValue:)) ?? argument.flatMap(Command.edgeAliases)
        switch head {
        case "arrange": self = .arrange
        case "relayout": self = .relayout
        case "back": self = .back
        case "forward": self = .forward
        case "zoom-out": self = .zoomOut
        case "zoom-in": self = .zoomIn
        case "overview": self = .overview
        case "maximize": self = .maximize
        case "toggle-float": self = .toggleFloat
        case "next-tab": self = .nextTab
        case "previous-tab": self = .previousTab
        case "focus":
            guard let edge else { return nil }
            self = .focus(edge)
        case "dock":
            guard let edge else { return nil }
            self = .dock(edge)
        case "view":
            guard let slot else { return nil }
            self = .view(slot)
        case "save-view":
            guard let slot else { return nil }
            self = .saveView(slot)
        default:
            return nil
        }
    }

    private static func edgeAliases(_ s: String) -> Edge? {
        switch s {
        case "up": return .top
        case "down": return .bottom
        default: return nil
        }
    }

    /// Every command, for menus and documentation.
    public static var all: [Command] {
        var result: [Command] = [.arrange, .relayout, .back, .forward, .zoomOut, .zoomIn, .overview, .maximize, .toggleFloat, .nextTab, .previousTab]
        result += Edge.allCases.map(Command.focus)
        result += Edge.allCases.map(Command.dock)
        result += (1...9).map(Command.view)
        result += (1...9).map(Command.saveView)
        return result
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
