#if os(macOS)
import AppKit
import ApplicationServices

/// Private but long-stable: returns the CGWindowID behind an AX window element. Used by
/// most macOS window managers, since AX has no public window identifier.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility permission, opening System Settings' prompt if needed.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        (value(attribute) as? NSNumber)?.boolValue
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (value(attribute) as? [AXUIElement]) ?? []
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    var position: CGPoint? {
        guard let v = value(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let v = value(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &size) ? size : nil
    }

    /// The frame in global top-left coordinates.
    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { set(kAXPositionAttribute, v) }
    }

    func setSize(_ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { set(kAXSizeAttribute, v) }
    }

    /// Size, then position, then size again: the first resize lets a window move to a
    /// smaller display, and the second applies once it's there.
    func setFrame(_ frame: CGRect) {
        setSize(frame.size)
        setPosition(frame.origin)
        setSize(frame.size)
    }

    func raise() {
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}

/// Snapshot of the window server's on-screen window list.
enum WindowList {
    struct Entry {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// On-screen windows on the current Space, front to back.
    static func onScreen() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return Entry(id: id, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// One window's bounds from the window server: cheap, and never blocks on the window's app.
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let boundsDict = info.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    static func onScreenIDs() -> Set<CGWindowID> {
        Set(onScreen().map(\.id))
    }

    /// The frontmost window at a point, ignoring our own windows. Menus, the Dock and
    /// other non-zero layers are returned too, so callers can leave clicks on them alone.
    static func frontmost(at point: CGPoint, excludingPID: pid_t) -> Entry? {
        onScreen().first { $0.pid != excludingPID && $0.layer >= 0 && $0.layer < 1000 && $0.bounds.contains(point) }
    }
}
#endif
