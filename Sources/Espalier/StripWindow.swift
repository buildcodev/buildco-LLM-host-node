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
/// The strip is a floating capsule of the system's glass (Liquid Glass on macOS 26, a
/// translucent blur before that), inset a little from the panel's edges.
final class StripPanel: NSPanel {
    let stripView = StripView()
    /// Space between the panel's edges and the glass capsule.
    static let glassInset = NSSize(width: 2, height: 3)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.ignoresCycle, .fullScreenNone]

        contentView = StripHostView(glass: StripPanel.makeGlass(content: stripView))
    }

    /// The glass behind the tabs, with `content` drawn in it.
    private static func makeGlass(content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = CapsuleGlassView()
            glass.style = .regular
            glass.contentView = content
            return glass
        }
        let effect = CapsuleBlurView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.addSubview(content)
        return effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the strip at `rect` (global, top-left coordinates), directly above `window`.
    /// While following a moving window, `restack` is off: the strip only moves, which keeps
    /// it from flickering.
    func show(at rect: Rect, above window: WindowID, restack: Bool = true) {
        let frame = Displays.cocoaRect(rect)
        if self.frame.size != frame.size {
            setFrame(frame, display: true)
            logger.debug("Strip is \(frame.width, privacy: .public)×\(frame.height, privacy: .public); tabs drawn in \(self.stripView.frame.width, privacy: .public)×\(self.stripView.frame.height, privacy: .public)")
        } else if self.frame.origin != frame.origin {
            setFrameOrigin(frame.origin)
        }
        guard restack || !isVisible else { return }
        // A strip left on another Space is ordered out first so it joins this one.
        if isVisible, !isOnActiveSpace { orderOut(nil) }
        order(.above, relativeTo: Int(window))
    }
}

/// The panel's content: the glass capsule, inset from the panel's edges. Sizes are set
/// directly whenever the panel resizes; resizing masks can't recover from the empty frame
/// a view starts with (insetting it gives a null rect), which left the tabs undrawn.
private final class StripHostView: NSView {
    let glass: NSView

    init(glass: NSView) {
        self.glass = glass
        super.init(frame: .zero)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let inset = StripPanel.glassInset
        glass.frame = NSRect(x: inset.width, y: inset.height,
                             width: max(0, newSize.width - 2 * inset.width), height: max(0, newSize.height - 2 * inset.height))
    }
}

/// Liquid Glass shaped as a capsule, whatever its height, with the tabs filling it.
@available(macOS 26.0, *)
private final class CapsuleGlassView: NSGlassEffectView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        cornerRadius = newSize.height / 2
        contentView?.frame = NSRect(origin: .zero, size: newSize)
    }
}

/// The pre-macOS 26 stand-in: a translucent blur shaped as a capsule.
private final class CapsuleBlurView: NSVisualEffectView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        wantsLayer = true
        layer?.cornerRadius = newSize.height / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        for view in subviews { view.frame = NSRect(origin: .zero, size: newSize) }
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
    private var hovered: WindowID?

    /// Room between the capsule's ends and the first and last tab.
    private static let endPadding: CGFloat = 4
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let activeTitleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tabArea: Rect {
        let inset = Double(StripView.endPadding)
        return Rect(x: inset, y: 0, width: max(0, Double(bounds.width) - 2 * inset), height: Double(bounds.height))
    }

    private func tabRects() -> [CGRect] {
        TabStripLayout.tabRects(in: tabArea, count: tabs.count, maxWidth: maxTabWidth).map(\.cgRect)
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override func draw(_ dirtyRect: NSRect) {
        let rects = tabRects()
        let activeIndex = tabs.firstIndex { $0 == active }
        for (i, (tab, r)) in zip(tabs, rects).enumerated() {
            let chip = r.insetBy(dx: 2, dy: 3)
            let look = look(tab)
            let isActive = tab == active
            if isActive {
                drawSelectedChip(chip, tint: look?.color)
            } else if tab == hovered, !dragging {
                let hover = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
                NSColor.labelColor.withAlphaComponent(isDark ? 0.10 : 0.07).setFill()
                hover.fill()
            }
            // A hairline between two tabs that aren't selected.
            if i + 1 < rects.count, !isActive, activeIndex != i + 1 {
                NSColor.labelColor.withAlphaComponent(0.16).setFill()
                NSRect(x: r.maxX - 0.5, y: r.minY + 10, width: 1, height: r.height - 20).fill()
            }
            drawLabel(look, in: chip, active: isActive)
        }
        if let insertion, dragging {
            let x = insertion < rects.count ? rects[insertion].minX : (rects.last?.maxX ?? 0)
            let marker = NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5)
            NSColor.controlAccentColor.setFill()
            marker.fill()
        }
    }

    /// The selected tab: a raised capsule, lightly tinted with its app's colour, with a fine
    /// highlight along its edge like the system's own glass controls.
    private func drawSelectedChip(_ chip: CGRect, tint: NSColor?) {
        let path = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
        NSColor.white.withAlphaComponent(isDark ? 0.16 : 0.62).setFill()
        path.fill()
        if let tint {
            tint.withAlphaComponent(isDark ? 0.22 : 0.16).setFill()
            path.fill()
        }
        NSColor.white.withAlphaComponent(isDark ? 0.28 : 0.75).setStroke()
        path.lineWidth = 0.75
        path.stroke()
    }

    private func drawLabel(_ look: WindowLook?, in chip: CGRect, active: Bool) {
        var textX = chip.minX + 10
        if let icon = look?.icon {
            let side = min(18, chip.height - 6)
            icon.draw(in: CGRect(x: chip.minX + 9, y: chip.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.85, respectFlipped: true, hints: nil)
            textX = chip.minX + 9 + side + 6
        }
        let font = active ? StripView.activeTitleFont : StripView.titleFont
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: active ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.72),
            .paragraphStyle: style,
        ]
        // Centred on the font's own height, so the text has even room above and below.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let rect = CGRect(x: textX, y: chip.midY - lineHeight / 2, width: max(0, chip.maxX - textX - 10), height: lineHeight)
        ((look?.title ?? "") as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let tab = tabRects().firstIndex { $0.contains(p) }.map { tabs[$0] }
        if tab != hovered {
            hovered = tab
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
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
        insertion = isNearStrip(p) ? TabStripLayout.insertionIndex(at: Double(p.x), in: tabArea, count: tabs.count, maxWidth: maxTabWidth) : nil
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
            var index = TabStripLayout.insertionIndex(at: Double(p.x), in: tabArea, count: tabs.count, maxWidth: maxTabWidth)
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
