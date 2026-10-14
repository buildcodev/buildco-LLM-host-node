#if os(macOS)
import AppKit
import Carbon.HIToolbox
import EspalierCore

/// Global shortcuts through Carbon's RegisterEventHotKey, which needs no extra permission.
final class HotkeyCenter {
    var onCommand: ((Command) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var commands: [UInt32: Command] = [:]
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4553_504C // "ESPL"

    /// Registers `bindings`, replacing any previous ones. Returns shortcuts that couldn't be registered.
    @discardableResult
    func register(_ bindings: [Hotkey: Command]) -> [String] {
        unregisterAll()
        installHandler()
        var problems: [String] = []
        var nextID: UInt32 = 1
        for (hotkey, command) in bindings.sorted(by: { $0.value.name < $1.value.name }) {
            guard let code = HotkeyCenter.keyCodes[hotkey.key] else {
                problems.append("No key code for \(hotkey)")
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotkeyCenter.signature, id: nextID)
            let status = RegisterEventHotKey(UInt32(code), HotkeyCenter.carbonModifiers(hotkey.modifiers), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                commands[nextID] = command
                nextID += 1
            } else {
                problems.append("\(hotkey) (\(command.name)) is already taken by another app")
            }
        }
        return problems
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        commands.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard let command = commands[id] else { return }
        onCommand?(command)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue().fire(hotKeyID.id)
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    private static func carbonModifiers(_ m: Hotkey.Modifiers) -> UInt32 {
        var result: UInt32 = 0
        if m.contains(.command) { result |= UInt32(cmdKey) }
        if m.contains(.option) { result |= UInt32(optionKey) }
        if m.contains(.control) { result |= UInt32(controlKey) }
        if m.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "return": kVK_Return, "space": kVK_Space, "tab": kVK_Tab, "escape": kVK_Escape, "delete": kVK_Delete,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in functionKeys.enumerated() { codes["f\(i + 1)"] = code }
        return codes
    }()
}

extension Hotkey {
    /// The key equivalent and modifier mask that show this shortcut in a menu.
    var menuEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        let special: [String: Int] = [
            "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey,
            "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
        ]
        if let code = special[key], let scalar = UnicodeScalar(code) { return (String(Character(scalar)), flags) }
        switch key {
        case "return": return ("\r", flags)
        case "space": return (" ", flags)
        case "tab": return ("\t", flags)
        case "escape": return ("\u{1b}", flags)
        default: return (key.count == 1 ? key : "", flags)
        }
    }
}
#endif
