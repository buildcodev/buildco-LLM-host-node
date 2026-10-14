#if os(macOS)
import AppKit
import EspalierCore

/// A connected display. Frames are in the Accessibility API's global top-left coordinates.
struct Display: Equatable {
    let id: CGDirectDisplayID
    let uuid: String
    let frame: Rect
    let visibleFrame: Rect
    let cocoaFrame: NSRect

    var screen: NSScreen? {
        NSScreen.screens.first { Displays.displayID(of: $0) == id }
    }

    /// Converts a global rect to this display's flipped view coordinates.
    func local(_ r: Rect) -> CGRect {
        CGRect(x: r.x - frame.x, y: r.y - frame.y, width: r.width, height: r.height)
    }

    /// Where to put a window of `size` so that only a sliver of it stays on this display,
    /// in a corner that doesn't touch another display.
    func parkingOrigin(for size: CGSize, among displays: [Display]) -> CGPoint {
        let w = Double(size.width), h = Double(size.height)
        let candidates = [
            Rect(x: frame.maxX - 1, y: frame.maxY - 1, width: w, height: h),     // bottom right
            Rect(x: frame.minX - w + 1, y: frame.maxY - 1, width: w, height: h), // bottom left
        ]
        let others = displays.filter { $0.id != id }
        let chosen = candidates.first { c in !others.contains { $0.frame.overlaps(c) } } ?? candidates[0]
        return CGPoint(x: chosen.x, y: chosen.y)
    }
}

enum Displays {
    static func all() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display-\(id)"
            return Display(id: id, uuid: uuid, frame: axRect(screen.frame), visibleFrame: axRect(screen.visibleFrame), cocoaFrame: screen.frame)
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The primary display (the one with the menu bar) anchors both coordinate systems.
    static var primaryHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    static func axRect(_ r: NSRect) -> Rect {
        Rect(x: Double(r.minX), y: primaryHeight - Double(r.maxY), width: Double(r.width), height: Double(r.height))
    }

    static func cocoaRect(_ r: Rect) -> NSRect {
        NSRect(x: r.x, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

extension Array where Element == Display {
    func containing(_ p: Point) -> Display? {
        first { $0.frame.contains(p) }
    }

    /// The display holding most of `r`, or the nearest one when it's off every display.
    func best(for r: Rect) -> Display? {
        if let d = containing(r.center) { return d }
        if let d = self.max(by: { $0.frame.intersection(r).area < $1.frame.intersection(r).area }), d.frame.intersection(r).area > 0 {
            return d
        }
        return self.min { a, b in
            hypot(a.frame.midX - r.midX, a.frame.midY - r.midY) < hypot(b.frame.midX - r.midX, b.frame.midY - r.midY)
        }
    }
}
#endif
