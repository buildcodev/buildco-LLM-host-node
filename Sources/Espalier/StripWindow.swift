#if os(macOS)
import AppKit
import EspalierCore

/// How to draw a window's tab: its app's colour and icon, and its title.
struct WindowLook {
    let color: NSColor
    let icon: NSImage?
    let title: String
}

/// A tab strip: a borderless panel that sits directly above a group's shown window.
/// It never becomes key or activates Espalier, so clicking a tab leaves focus with the app.
final class StripPanel: NSPanel {
    let stripView = StripView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        effect.layer?.masksToBounds = true
        stripView.autoresizingMask = [.width, .height]
        effect.addSubview(stripView)
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the strip at `rect` (global, top-left coordinates), directly above `window`.
    func show(at rect: Rect, above window: WindowID) {
        let frame = Displays.cocoaRect(rect)
        if self.frame != frame { setFrame(frame, display: true) }
        stripView.frame = contentView?.bounds ?? .zero
        // A strip left on another Space is ordered out first so it joins this one.
        if isVisible, !isOnActiveSpace { orderOut(nil) }
        order(.above, relativeTo: Int(window))
    }
}

/// Draws the tabs and turns clicks and drags into tab actions.
final class StripView: NSView {
    var tabs: [WindowID] = []
    var active: WindowID?
    var maxTabWidth: Double = 280
    var look: (WindowID) -> WindowLook? = { _ in nil }
    var onSelect: ((WindowID) -> Void)?
    /// A tab dragged along the strip and let go: the tab and its new index.
    var onReorder: ((WindowID, Int) -> Void)?
    /// A tab dragged off the strip: the tab and where it was let go (global, top-left coordinates).
    var onTearOff: ((WindowID, Point) -> Void)?

    private var pressed: (tab: WindowID, at: NSPoint)?
    private var dragging = false
    private var insertion: Int?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var bounds2: Rect { Rect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height)) }

    private func tabRects() -> [CGRect] {
        TabStripLayout.tabRects(in: bounds2, count: tabs.count, maxWidth: maxTabWidth).map(\.cgRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (tab, r) in zip(tabs, tabRects()) {
            let rect = r.insetBy(dx: 3, dy: 3)
            let look = look(tab)
            let isActive = tab == active
            if isActive {
                let chip = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
                (look?.color ?? .controlAccentColor).withAlphaComponent(0.45).setFill()
                chip.fill()
                NSColor.white.withAlphaComponent(0.25).setStroke()
                chip.lineWidth = 1
                chip.stroke()
            } else if r.maxX < bounds.width - 1 {
                NSColor.labelColor.withAlphaComponent(0.15).setFill()
                NSRect(x: r.maxX - 0.5, y: r.minY + 8, width: 1, height: r.height - 16).fill()
            }
            var textX = rect.minX + 8
            if let icon = look?.icon {
                let side = min(16, rect.height - 6)
                icon.draw(in: CGRect(x: rect.minX + 7, y: rect.midY - side / 2, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: isActive ? 1 : 0.8, respectFlipped: true, hints: nil)
                textX += side + 4
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]
            ((look?.title ?? "") as NSString).draw(in: CGRect(x: textX, y: rect.midY - 8, width: max(0, rect.maxX - textX - 6), height: 17), withAttributes: attributes)
        }
        if let insertion, dragging {
            let rects = tabRects()
            let x = insertion < rects.count ? rects[insertion].minX : (rects.last?.maxX ?? 0)
            NSColor.controlAccentColor.setFill()
            NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = tabRects().firstIndex(where: { $0.contains(p) }) else { return }
        pressed = (tabs[i], p)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 6 { dragging = true }
        guard dragging else { return }
        insertion = isNearStrip(p) ? TabStripLayout.insertionIndex(at: Double(p.x), in: bounds2, count: tabs.count, maxWidth: maxTabWidth) : nil
        NSCursor.closedHand.set()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            dragging = false
            insertion = nil
            NSCursor.arrow.set()
            needsDisplay = true
        }
        guard let pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging {
            onSelect?(pressed.tab)
        } else if isNearStrip(p) {
            var index = TabStripLayout.insertionIndex(at: Double(p.x), in: bounds2, count: tabs.count, maxWidth: maxTabWidth)
            if let from = tabs.firstIndex(of: pressed.tab), from < index { index -= 1 }
            onReorder?(pressed.tab, index)
        } else {
            let global = NSEvent.mouseLocation
            onTearOff?(pressed.tab, Point(x: Double(global.x), y: Displays.primaryHeight - Double(global.y)))
        }
    }

    /// Within the strip, give or take a little above and below.
    private func isNearStrip(_ p: NSPoint) -> Bool {
        p.y > -20 && p.y < bounds.height + 20 && p.x >= 0 && p.x <= bounds.width
    }
}

/// The outline shown over a window's title bar or a strip while a dragged window would
/// become a tab there. It ignores the mouse.
final class DropHighlight {
    private let window: NSWindow

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        window.contentView = HighlightView()
    }

    func show(_ rect: Rect?) {
        guard let rect else {
            window.orderOut(nil)
            return
        }
        window.setFrame(Displays.cocoaRect(rect), display: true)
        window.orderFrontRegardless()
    }

    private final class HighlightView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }
}
#endif
