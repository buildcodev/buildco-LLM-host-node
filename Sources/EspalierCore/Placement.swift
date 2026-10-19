import Foundation

/// Where a tab strip and its tabs go. The strip sits directly above the shown window,
/// as wide as it.
public enum TabStripLayout {
    public static func strip(above window: Rect, height: Double) -> Rect {
        Rect(x: window.x, y: window.y - height, width: window.width, height: height)
    }

    /// The window frame that leaves room for the strip at the top of `region`, so the strip
    /// and the window together fill what another tool (such as Grid) gave the window.
    public static func window(fitting region: Rect, stripHeight: Double) -> Rect {
        Rect(x: region.x, y: region.y + stripHeight, width: region.width, height: max(0, region.height - stripHeight))
    }

    /// The space a window and its strip take together.
    public static func region(of window: Rect, stripHeight: Double) -> Rect {
        Rect(x: window.x, y: window.y - stripHeight, width: window.width, height: window.height + stripHeight)
    }

    /// Each tab's rect in a strip: equal widths up to `maxWidth`, from the left.
    public static func tabRects(in strip: Rect, count: Int, maxWidth: Double) -> [Rect] {
        guard count > 0 else { return [] }
        let width = min(maxWidth, strip.width / Double(count))
        return (0..<count).map { Rect(x: strip.x + Double($0) * width, y: strip.y, width: width, height: strip.height) }
    }

    /// The tab under `x`, if any.
    public static func tabIndex(at x: Double, in strip: Rect, count: Int, maxWidth: Double) -> Int? {
        tabRects(in: strip, count: count, maxWidth: maxWidth).firstIndex { x >= $0.minX && x < $0.maxX }
    }

    /// Where a tab let go at `x` would be inserted, from 0 to `count`.
    public static func insertionIndex(at x: Double, in strip: Rect, count: Int, maxWidth: Double) -> Int {
        let rects = tabRects(in: strip, count: count, maxWidth: maxWidth)
        return rects.firstIndex { x < $0.midX } ?? count
    }
}

/// Which half of a display a window was snapped to.
public enum Side: String, Codable, Sendable, CaseIterable {
    case left, right

    public var opposite: Side { self == .left ? .right : .left }
}

/// Two windows snapped side by side (by Grid, for example), where one of them may need
/// more than half the width.
public enum SideBySide {
    /// The half a frame looks snapped to: nearly the display's full height, between about
    /// a third and three quarters of its width, against the left edge (left), or starting
    /// at the middle or ending at the right edge (right). An app that wouldn't shrink to
    /// half still counts, since it keeps the edge it was put against.
    public static func side(of frame: Rect, in visible: Rect, tolerance: Double = 16) -> Side? {
        guard frame.height >= visible.height * 0.85,
              frame.width >= visible.width * 0.3, frame.width <= visible.width * 0.75
        else { return nil }
        if abs(frame.minX - visible.minX) <= tolerance { return .left }
        if abs(frame.minX - visible.midX) <= tolerance || abs(frame.maxX - visible.maxX) <= tolerance { return .right }
        return nil
    }

    /// Where the two halves meet. Normally the middle. When one side needs more than half
    /// (an app that won't get narrower), the line moves to give it that, as long as the
    /// other side keeps what it needs. When both can't fit, the width is shared in
    /// proportion to what each needs.
    public static func divider(in visible: Rect, leftNeeds: Double, rightNeeds: Double) -> Double {
        let left = max(0, leftNeeds), right = max(0, rightNeeds)
        if left + right <= visible.width {
            return min(max(visible.midX, visible.minX + left), visible.maxX - right)
        }
        return visible.minX + visible.width * left / (left + right)
    }

    /// One side's frame with the halves meeting at `divider`. The frame keeps its own top
    /// and height, since the tool that snapped it chose those.
    public static func frame(for side: Side, keeping frame: Rect, in visible: Rect, divider: Double) -> Rect {
        switch side {
        case .left: return Rect(x: visible.minX, y: frame.y, width: divider - visible.minX, height: frame.height)
        case .right: return Rect(x: divider, y: frame.y, width: visible.maxX - divider, height: frame.height)
        }
    }
}
