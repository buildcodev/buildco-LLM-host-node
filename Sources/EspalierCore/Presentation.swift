import Foundation

/// Sizes and thresholds that shape the layout on screen. Every value can be set in
/// the config file; missing keys keep their defaults.
public struct LayoutMetrics: Codable, Equatable, Sendable {
    /// Space between docked windows.
    public var gap: Double = 8
    /// Space between docked windows and the edge of the screen.
    public var margin: Double = 8
    /// Height of the tab strip drawn above a tab group with more than one window.
    public var tabBarHeight: Double = 28
    /// Below this size a docked window is drawn as an icon tile instead of being shown.
    public var usableSize = Size(width: 240, height: 150)
    /// When every leaf of a nested group is narrower or shorter than this, the group becomes one tile.
    public var collapseSize = Size(width: 56, height: 56)
    /// Dropping on the top of a docked window (its title bar) adds the dragged window as a tab.
    public var titleZoneHeight: Double = 36
    /// Width of the docking band along a window's edges, as a fraction of its size, clamped to a pixel range.
    public var edgeBandFraction: Double = 0.14
    public var edgeBandMin: Double = 24
    public var edgeBandMax: Double = 96
    /// Docking band along the desktop's edges: this fraction of its size, but no more than `desktopBandMax`.
    public var desktopBandFraction: Double = 0.28
    public var desktopBandMax: Double = 64
    /// Dropping within this distance of the screen's edge docks beside everything on screen.
    public var screenEdgeBand: Double = 20
    /// Dragging a gap can't make either neighbour smaller than this.
    public var minimumSpan: Double = 120
    /// Extra pixels on each side of a gap that still grab it.
    public var dividerSlop: Double = 4

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LayoutMetrics()
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
        tabBarHeight = try c.decodeIfPresent(Double.self, forKey: .tabBarHeight) ?? d.tabBarHeight
        usableSize = try c.decodeIfPresent(Size.self, forKey: .usableSize) ?? d.usableSize
        collapseSize = try c.decodeIfPresent(Size.self, forKey: .collapseSize) ?? d.collapseSize
        titleZoneHeight = try c.decodeIfPresent(Double.self, forKey: .titleZoneHeight) ?? d.titleZoneHeight
        edgeBandFraction = try c.decodeIfPresent(Double.self, forKey: .edgeBandFraction) ?? d.edgeBandFraction
        edgeBandMin = try c.decodeIfPresent(Double.self, forKey: .edgeBandMin) ?? d.edgeBandMin
        edgeBandMax = try c.decodeIfPresent(Double.self, forKey: .edgeBandMax) ?? d.edgeBandMax
        desktopBandFraction = try c.decodeIfPresent(Double.self, forKey: .desktopBandFraction) ?? d.desktopBandFraction
        desktopBandMax = try c.decodeIfPresent(Double.self, forKey: .desktopBandMax) ?? d.desktopBandMax
        screenEdgeBand = try c.decodeIfPresent(Double.self, forKey: .screenEdgeBand) ?? d.screenEdgeBand
        minimumSpan = try c.decodeIfPresent(Double.self, forKey: .minimumSpan) ?? d.minimumSpan
        dividerSlop = try c.decodeIfPresent(Double.self, forKey: .dividerSlop) ?? d.dividerSlop
    }
}

/// An overlay tile, drawn where a real window can't be shown.
public struct Tile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A docked window too small to use, or partly off screen. Drawn as its app's colour and icon.
        case window(WindowID)
        /// The desktop, when it's too small to hold floating windows.
        case desktop
        /// A nested group too small to show its parts, drawn as one tile lined with its splits.
        case group
    }

    public var node: NodeID
    public var kind: Kind
    public var rect: Rect
    /// The windows the tile stands for, in tree order. The first one supplies a group tile's colour.
    public var windows: [WindowID]
    /// Split lines for group tiles, two levels deep.
    public var lines: [LineSegment]
}

/// The tab strip drawn above a tab group with more than one window.
public struct TabStrip: Equatable, Sendable {
    public var group: NodeID
    public var rect: Rect
    public var tabs: [WindowID]
    public var active: WindowID

    /// The rect of each tab inside the strip, in order.
    public var tabRects: [Rect] {
        rect.divided(along: .horizontal, weights: tabs.map { _ in 1 })
    }

    public func tab(at p: Point) -> WindowID? {
        guard rect.contains(p) else { return nil }
        for (tab, r) in zip(tabs, tabRects) where r.contains(p) { return tab }
        return nil
    }
}

/// The gap between two neighbouring nodes of a split. Dragging it resizes both.
public struct Divider: Equatable, Sendable {
    public var split: NodeID
    public var before: NodeID
    public var after: NodeID
    public var axis: Axis
    /// The area that grabs the divider, including slop.
    public var hitRect: Rect
    /// Where the `before` node starts and the `after` node ends on screen, along `axis`.
    public var start: Double
    public var end: Double
    /// The current position of the divider's centre along `axis`.
    public var position: Double
}

/// Everything needed to put one display on screen for one camera position.
public struct Presentation: Equatable, Sendable {
    public var target: LayoutTarget
    /// The world rect the camera shows.
    public var camera: Rect
    /// The display's usable frame (its visible frame, below the menu bar and beside the Dock).
    public var screen: Rect
    /// Screen rects of every present node, gaps applied, including nodes off screen.
    public var nodeRects: [NodeID: Rect] = [:]
    /// Docked windows to show, and where.
    public var windowFrames: [WindowID: Rect] = [:]
    /// Docked windows to hide (park) because they're off camera, too small, or background tabs.
    public var parked: Set<WindowID> = []
    public var tiles: [Tile] = []
    public var tabStrips: [TabStrip] = []
    public var dividers: [Divider] = []
    /// The desktop's screen rect when it's on screen and big enough for floating windows.
    public var desktopRect: Rect?

    /// The leaf or collapsed tile under a screen point.
    public func tile(at p: Point) -> Tile? {
        tiles.first { $0.rect.contains(p) }
    }

    public func divider(at p: Point) -> Divider? {
        dividers.first { $0.hitRect.contains(p) }
    }

    public func tabStrip(at p: Point) -> TabStrip? {
        tabStrips.first { $0.rect.contains(p) }
    }
}

extension Layout {
    /// Computes what the display shows with the camera on `target` (or on an explicit
    /// world rect, for animation frames).
    ///
    /// - Parameter minSizes: smallest sizes windows are known to accept. A window whose
    ///   slot is smaller than that is drawn as a tile instead of overlapping its neighbours.
    public func presentation(
        target: LayoutTarget,
        screen: Rect,
        metrics: LayoutMetrics,
        minSizes: [WindowID: Size] = [:],
        camera: Rect? = nil
    ) -> Presentation {
        let fractions = LayoutGeometry.rects(root)
        let world = camera ?? worldRect(for: target, rects: fractions)
        let content = screen.inset(max(0, metrics.margin - metrics.gap / 2))
        var p = Presentation(target: target, camera: world, screen: screen)
        for (id, r) in fractions {
            p.nodeRects[id] = Camera.map(r, world: world, onto: content).inset(metrics.gap / 2)
        }
        p.parked = Set(presentWindows)
        let protected = Set(nodes(of: target).map(\.id)).union(ancestors(of: target))
        var walker = PresentationWalker(
            fractions: fractions, world: world, metrics: metrics,
            minSizes: minSizes, protected: protected, presentation: p
        )
        walker.walk(root)
        return walker.presentation
    }

    private func ancestors(of target: LayoutTarget) -> Set<NodeID> {
        let id: NodeID
        switch target {
        case .node(let n): id = n
        case .siblings(let s, _): id = s
        }
        return Set(root.path(to: id) ?? [])
    }
}

private struct PresentationWalker {
    let fractions: [NodeID: Rect]
    let world: Rect
    let metrics: LayoutMetrics
    let minSizes: [WindowID: Size]
    /// The framed nodes and their ancestors never collapse into a tile.
    let protected: Set<NodeID>
    var presentation: Presentation

    var screen: Rect { presentation.screen }

    mutating func walk(_ node: LayoutNode) {
        guard node.isPresent, let fraction = fractions[node.id], fraction.overlaps(world, epsilon: 1e-9),
              let rect = presentation.nodeRects[node.id]
        else { return }
        switch node {
        case .split(let s):
            if !protected.contains(s.id), shouldCollapse(s) {
                presentation.tiles.append(Tile(
                    node: s.id, kind: .group, rect: rect,
                    windows: node.allNodes.compactMap(\.asGroup).compactMap(\.activeWindow),
                    lines: lines(for: s, depth: 2)
                ))
                return
            }
            for i in s.presentIndices { walk(s.children[i]) }
            addDividers(for: s)
        case .group(let g):
            guard let active = g.activeWindow else { return }
            let present = g.presentWindows
            var windowRect = rect
            var strip: TabStrip?
            if present.count > 1 {
                let height = min(metrics.tabBarHeight, rect.height / 3)
                strip = TabStrip(group: g.id, rect: Rect(x: rect.x, y: rect.y, width: rect.width, height: height), tabs: present, active: active)
                windowRect = Rect(x: rect.x, y: rect.y + height, width: rect.width, height: rect.height - height)
            }
            var need = metrics.usableSize
            if let known = minSizes[active] {
                need = Size(width: max(need.width, known.width), height: max(need.height, known.height))
            }
            if windowRect.size.fits(need), screen.contains(rect, tolerance: 1) {
                presentation.windowFrames[active] = windowRect
                presentation.parked.remove(active)
                if let strip { presentation.tabStrips.append(strip) }
            } else if rect.overlaps(screen) {
                presentation.tiles.append(Tile(node: g.id, kind: .window(active), rect: rect, windows: present, lines: []))
            }
        case .desktop(let id):
            if rect.size.fits(metrics.usableSize), screen.contains(rect, tolerance: 1) {
                presentation.desktopRect = rect
            } else if rect.overlaps(screen) {
                presentation.tiles.append(Tile(node: id, kind: .desktop, rect: rect, windows: [], lines: []))
            }
        }
    }

    /// A nested group collapses when every leaf in it is too small for even an icon.
    /// A flat row or column keeps its individual tiles.
    private func shouldCollapse(_ s: Split) -> Bool {
        guard s.presentIndices.contains(where: { !s.children[$0].isLeaf }) else { return false }
        let leaves = LayoutNode.split(s).allNodes.filter { $0.isLeaf && $0.isPresent }
        return leaves.allSatisfy { leaf in
            guard let r = presentation.nodeRects[leaf.id] else { return true }
            return r.width < metrics.collapseSize.width || r.height < metrics.collapseSize.height
        }
    }

    private func lines(for s: Split, depth: Int) -> [LineSegment] {
        guard depth > 0, let bounds = presentation.nodeRects[s.id] else { return [] }
        var result: [LineSegment] = []
        let present = s.presentIndices
        for (a, b) in zip(present, present.dropFirst()) {
            guard let ra = presentation.nodeRects[s.children[a].id], let rb = presentation.nodeRects[s.children[b].id] else { continue }
            let position = (ra.end(along: s.axis) + rb.start(along: s.axis)) / 2
            if s.axis == .horizontal {
                result.append(LineSegment(from: Point(x: position, y: bounds.minY), to: Point(x: position, y: bounds.maxY)))
            } else {
                result.append(LineSegment(from: Point(x: bounds.minX, y: position), to: Point(x: bounds.maxX, y: position)))
            }
        }
        for i in present {
            if case .split(let inner) = s.children[i] {
                result += lines(for: inner, depth: depth - 1)
            }
        }
        return result
    }

    private mutating func addDividers(for s: Split) {
        guard let bounds = presentation.nodeRects[s.id] else { return }
        let present = s.presentIndices
        for (a, b) in zip(present, present.dropFirst()) {
            let before = s.children[a], after = s.children[b]
            guard let ra = presentation.nodeRects[before.id], let rb = presentation.nodeRects[after.id],
                  ra.overlaps(screen), rb.overlaps(screen)
            else { continue }
            let slop = metrics.dividerSlop
            let lo = ra.end(along: s.axis), hi = rb.start(along: s.axis)
            let hit: Rect
            if s.axis == .horizontal {
                hit = Rect(x: lo - slop, y: bounds.minY, width: hi - lo + 2 * slop, height: bounds.height)
            } else {
                hit = Rect(x: bounds.minX, y: lo - slop, width: bounds.width, height: hi - lo + 2 * slop)
            }
            presentation.dividers.append(Divider(
                split: s.id, before: before.id, after: after.id, axis: s.axis,
                hitRect: hit.intersection(screen),
                start: ra.start(along: s.axis), end: rb.end(along: s.axis),
                position: (lo + hi) / 2
            ))
        }
    }
}
