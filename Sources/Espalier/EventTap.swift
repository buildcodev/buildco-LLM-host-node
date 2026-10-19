#if os(macOS)
import AppKit

protocol EventTapHandler: AnyObject {
    /// Each returns true to swallow the event.
    func mouseDown(at point: CGPoint, clickCount: Int, flags: CGEventFlags) -> Bool
    func mouseDragged(to point: CGPoint, flags: CGEventFlags) -> Bool
    func mouseUp(at point: CGPoint, flags: CGEventFlags) -> Bool
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// A session event tap that watches left-mouse drags, for dragging a window onto another's title bar.
final class EventTap {
    weak var handler: EventTapHandler?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }
        let types: [UInt32] = [
            CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue,
            CGEventType.leftMouseDragged.rawValue,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1)) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Couldn't create the event tap; is Accessibility permission granted?")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard let handler else { return false }
        let point = event.location
        switch type.rawValue {
        case CGEventType.leftMouseDown.rawValue:
            return handler.mouseDown(at: point, clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), flags: event.flags)
        case CGEventType.leftMouseDragged.rawValue:
            return handler.mouseDragged(to: point, flags: event.flags)
        case CGEventType.leftMouseUp.rawValue:
            return handler.mouseUp(at: point, flags: event.flags)
        default:
            return false
        }
    }
}

extension CGEventFlags {
    /// Whether the modifier named in the config ("shift", "alt", "ctrl", "cmd") is held.
    func contains(modifierNamed name: String) -> Bool {
        switch name.lowercased() {
        case "shift": return contains(.maskShift)
        case "alt", "opt", "option": return contains(.maskAlternate)
        case "ctrl", "control": return contains(.maskControl)
        case "cmd", "command": return contains(.maskCommand)
        default: return false
        }
    }
}
#endif
