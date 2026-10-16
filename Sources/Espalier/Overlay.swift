#if os(macOS)
import AppKit
import EspalierCore

/// How to draw a window that can't be shown: its app's colour and icon, and its title.
struct WindowLook {
    let color: NSColor
    let icon: NSImage?
    let title: String
    let snapshot: NSImage?
}

/// One thing moving during a camera animation.
struct Proxy {
    enum Kind { case window, desktop }
    var kind: Kind
    var from: CGRect
    var to: CGRect
    var look: WindowLook?
}

private enum Drawing {
    static let cornerRadius: CGFloat = 10

    static func window(_ rect: CGRect, look: WindowLook?, useSnapshot: Bool) {
        guard rect.width > 1, rect.height > 1 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        if useSnapshot, let snapshot = look?.snapshot {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            snapshot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            (look?.color ?? .systemGray).withAlphaComponent(0.92).setFill()
            path.fill()
            if let icon = look?.icon {
                let side = min(72, min(rect.width, rect.height) * 0.5)
                if side >= 12 {
                    let iconRect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2 - (rect.height > 120 ? 10 : 0), width: side, height: side)
                    icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    if let title = look?.title, !title.isEmpty, rect.height > 120, rect.width > 90 {
                        label(title, in: CGRect(x: rect.minX + 8, y: iconRect.maxY + 6, width: rect.width - 16, height: 18), size: 12)
                    }
                }
            }
        }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func group(_ rect: CGRect, color: NSColor, lines: [(CGPoint, CGPoint)]) {
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        color.withAlphaComponent(0.85).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        for (a, b) in lines {
            let line = NSBezierPath()
            line.move(to: a)
            line.line(to: b)
            line.lineWidth = 1.5
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func desktop(_ rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.lineWidth = 1.5
        path.stroke()
        if rect.width > 80, rect.height > 40 {
            label("Desktop", in: CGRect(x: rect.minX, y: rect.midY - 9, width: rect.width, height: 18), size: 12)
        }
    }

    static func label(_ text: String, in rect: CGRect, size: CGFloat, alignment: NSTextAlignment = .center, color: NSColor = .white) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

/// Draws tiles and tab strips. Lives just above the wallpaper, below every window.
final class TileView: NSView {
    var origin = CGPoint.zero
    var tiles: [Tile] = []
    var strips: [TabStrip] = []
    var look: (WindowID) -> WindowLook? = { _ in nil }

    override var isFlipped: Bool { true }

    private func local(_ r: Rect) -> CGRect {
        CGRect(x: r.x - origin.x, y: r.y - origin.y, width: r.width, height: r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        for tile in tiles {
            let rect = local(tile.rect)
            switch tile.kind {
            case .window(let id):
                Drawing.window(rect, look: look(id), useSnapshot: false)
            case .desktop:
                Drawing.desktop(rect)
            case .group:
                let color = tile.windows.first.flatMap(look)?.color ?? .systemGray
                let lines = tile.lines.map { segment in
                    (CGPoint(x: segment.from.x - origin.x, y: segment.from.y - origin.y),
                     CGPoint(x: segment.to.x - origin.x, y: segment.to.y - origin.y))
                }
                Drawing.group(rect, color: color, lines: lines)
            }
        }
        for strip in strips { drawStrip(strip) }
    }

    private func drawStrip(_ strip: TabStrip) {
        let rect = local(strip.rect)
        let background = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.55).setFill()
        background.fill()
        for (tab, r) in zip(strip.tabs, strip.tabRects) {
            let tabRect = local(r).insetBy(dx: 2, dy: 3)
            let look = look(tab)
            if tab == strip.active {
                let highlight = NSBezierPath(roundedRect: tabRect, xRadius: 6, yRadius: 6)
                (look?.color ?? .controlAccentColor).withAlphaComponent(0.85).setFill()
                highlight.fill()
            }
            var textX = tabRect.minX + 8
            if let icon = look?.icon {
                let side = min(16, tabRect.height - 4)
                icon.draw(in: CGRect(x: tabRect.minX + 6, y: tabRect.midY - side / 2, width: side, height: side),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                textX += side + 4
            }
            Drawing.label(look?.title ?? "", in: CGRect(x: textX, y: tabRect.midY - 8, width: tabRect.maxX - textX - 6, height: 16),
                          size: 11.5, alignment: .left, color: tab == strip.active ? .white : NSColor.white.withAlphaComponent(0.75))
        }
    }
}

/// Draws camera animations and the drop preview, above every window.
final class MotionView: NSView {
    var wallpaper: NSImage?
    var proxies: [Proxy] = []
    var progress: Double = 0
    var animating = false
    var useSnapshots = false
    var preview: CGRect?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if animating {
            if let wallpaper {
                // Aspect-fill the wallpaper to hide the windows jumping into place underneath.
                let size = wallpaper.size
                let scale = max(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
                let w = size.width * scale, h = size.height * scale
                wallpaper.draw(in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h),
                               from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor(white: 0.12, alpha: 1).setFill()
                bounds.fill()
            }
            let t = CGFloat(progress)
            for proxy in proxies {
                let r = CGRect(
                    x: proxy.from.minX + (proxy.to.minX - proxy.from.minX) * t,
                    y: proxy.from.minY + (proxy.to.minY - proxy.from.minY) * t,
                    width: proxy.from.width + (proxy.to.width - proxy.from.width) * t,
                    height: proxy.from.height + (proxy.to.height - proxy.from.height) * t
                )
                switch proxy.kind {
                case .desktop: Drawing.desktop(r)
                case .window: Drawing.window(r, look: proxy.look, useSnapshot: useSnapshots)
                }
            }
        }
        if let preview {
            let path = NSBezierPath(roundedRect: preview, xRadius: 10, yRadius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }
}

/// The two overlay windows of one display.
final class OverlayController {
    let display: Display
    private let tileWindow: NSWindow
    private let tileView = TileView()
    private let motionWindow: NSWindow
    private let motionView = MotionView()
    private var timer: Timer?
    private var start: CFTimeInterval = 0
    private var duration: Double = 0
    private var completion: (() -> Void)?

    init(display: Display, look: @escaping (WindowID) -> WindowLook?) {
        self.display = display
        let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        tileWindow = OverlayController.makeWindow(frame: display.cocoaFrame, level: desktopLevel)
        motionWindow = OverlayController.makeWindow(frame: display.cocoaFrame, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        tileView.origin = CGPoint(x: display.frame.x, y: display.frame.y)
        tileView.look = look
        tileWindow.contentView = tileView
        motionWindow.contentView = motionView
        if let screen = display.screen, let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            motionView.wallpaper = NSImage(contentsOf: url)
        }
        tileWindow.orderFrontRegardless()
    }

    private static func makeWindow(frame: NSRect, level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: false)
        return window
    }

    func update(tiles: [Tile], strips: [TabStrip]) {
        tileView.tiles = tiles
        tileView.strips = strips
        tileView.needsDisplay = true
    }

    func redrawTiles() {
        tileView.needsDisplay = true
    }

    func showPreview(_ rect: Rect?) {
        motionView.preview = rect.map(display.local)
        motionView.needsDisplay = true
        if rect != nil {
            motionWindow.orderFrontRegardless()
        } else if !motionView.animating {
            motionWindow.orderOut(nil)
        }
    }

    var isAnimating: Bool { motionView.animating }

    /// Shows `proxies` moving over the wallpaper for `duration` seconds, then hides the layer.
    func animate(_ proxies: [Proxy], useSnapshots: Bool, duration: Double, completion: @escaping () -> Void) {
        finishAnimation()
        motionView.proxies = proxies
        motionView.useSnapshots = useSnapshots
        motionView.progress = 0
        motionView.animating = true
        motionView.needsDisplay = true
        motionWindow.alphaValue = 1
        motionWindow.orderFrontRegardless()
        self.duration = max(duration, 0.01)
        self.completion = completion
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        // Cubic ease in-out.
        motionView.progress = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        motionView.needsDisplay = true
        if t >= 1 { finishAnimation() }
    }

    /// Ends the current animation immediately (if any) and calls its completion.
    func finishAnimation() {
        guard motionView.animating else { return }
        timer?.invalidate()
        timer = nil
        motionView.animating = false
        motionView.proxies = []
        motionView.needsDisplay = true
        if motionView.preview == nil { motionWindow.orderOut(nil) }
        let done = completion
        completion = nil
        done?()
    }

    func close() {
        finishAnimation()
        tileWindow.orderOut(nil)
        motionWindow.orderOut(nil)
    }
}
#endif
