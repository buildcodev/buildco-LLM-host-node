import Foundation

/// What Espalier remembers about a window so it can find it again after a restart.
public struct WindowInfo: Codable, Hashable, Sendable {
    public var bundleID: String
    public var title: String

    public init(bundleID: String, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

/// What releasing a dragged window would do.
public enum DropAction: Equatable, Sendable {
    /// Dock beside a node or sibling range, at one of its edges.
    case dock(LayoutTarget, Edge)
    /// Add to a tab group.
    case tab(NodeID)
    /// Float on the desktop where it was released.
    case float
    /// Nothing: a docked window snaps back to its slot.
    case none
}

/// How a window changed while the user held the mouse down on it.
public enum FrameChange: Equatable, Sendable {
    case none, moved, resized

    /// A size change beyond rounding is a resize, even if the origin moved too (dragging
    /// the left or top border moves it). Otherwise a moved origin is a move.
    public init(from old: Rect, to new: Rect) {
        if abs(new.width - old.width) > 1 || abs(new.height - old.height) > 1 {
            self = .resized
        } else if abs(new.x - old.x) > 2 || abs(new.y - old.y) > 2 {
            self = .moved
        } else {
            self = .none
        }
    }
}

/// One display's layout, camera and floating windows.
public struct DisplayState: Codable, Equatable, Sendable {
    public var layout: Layout
    public var navigation: Navigation
    /// The last frame of each floating window on this display, as the user left it.
    public var floating: [WindowID: Rect]
    public var windowInfo: [WindowID: WindowInfo]

    public init(layout: Layout = Layout(), navigation: Navigation = Navigation(), floating: [WindowID: Rect] = [:], windowInfo: [WindowID: WindowInfo] = [:]) {
        self.layout = layout
        self.navigation = navigation
        self.floating = floating
        self.windowInfo = windowInfo
    }

    public var target: LayoutTarget { layout.resolve(navigation.current) }

    public func presentation(screen: Rect, metrics: LayoutMetrics, minSizes: [WindowID: Size] = [:], camera: Rect? = nil) -> Presentation {
        layout.presentation(target: target, screen: screen, metrics: metrics, minSizes: minSizes, camera: camera)
    }

    public func isDocked(_ window: WindowID) -> Bool { layout.isDocked(window) }
    public func isFloating(_ window: WindowID) -> Bool { floating[window] != nil }
    public func manages(_ window: WindowID) -> Bool { isDocked(window) || isFloating(window) }

    public var managedWindows: Set<WindowID> {
        Set(layout.allWindows).union(floating.keys)
    }

    // MARK: Window lifecycle

    /// A window appeared on this display. It floats on the desktop, and the camera widens to show the desktop.
    public mutating func adoptFloating(_ window: WindowID, frame: Rect, info: WindowInfo?) {
        if let info { windowInfo[window] = info }
        guard !isDocked(window) else { return }
        floating[window] = frame
        reveal(window, screen: nil, metrics: nil)
    }

    /// A window closed, or moved to another display.
    public mutating func forget(_ window: WindowID) {
        layout.remove(window)
        floating[window] = nil
        windowInfo[window] = nil
        navigation.prune(keeping: managedWindows)
    }

    public mutating func setSuspended(_ window: WindowID, _ suspended: Bool) {
        layout.setSuspended(window, suspended)
    }

    public mutating func noteFloatingFrame(_ window: WindowID, _ frame: Rect) {
        if floating[window] != nil { floating[window] = frame }
    }

    /// Matches restored ids to live windows (see `WindowMatcher`) and drops the rest.
    public mutating func remap(_ mapping: [WindowID: WindowID]) {
        layout.remap(mapping)
        navigation.remap(mapping)
        var floats: [WindowID: Rect] = [:]
        for (old, frame) in floating { if let new = mapping[old] { floats[new] = frame } }
        floating = floats
        var infos: [WindowID: WindowInfo] = [:]
        for (old, info) in windowInfo { if let new = mapping[old] { infos[new] = info } }
        windowInfo = infos
        navigation.prune(keeping: managedWindows)
    }

    // MARK: Navigation

    public mutating func zoomOut() {
        guard let parent = layout.parentTarget(of: target) else { return }
        navigation.go(to: layout.framing(for: parent))
    }

    /// Steps one level in, towards a screen point (or the middle of the screen).
    public mutating func zoomIn(toward point: Point?, screen: Rect, metrics: LayoutMetrics) {
        let fractions = LayoutGeometry.rects(layout.root)
        let world = layout.worldRect(for: target, rects: fractions)
        let content = screen.inset(max(0, metrics.margin - metrics.gap / 2))
        let p = point.map { Camera.unmap($0, world: world, from: content) } ?? world.center
        guard let child = layout.childTarget(of: target, toward: p, rects: fractions) else { return }
        navigation.go(to: layout.framing(for: child))
    }

    public mutating func toggleOverview() {
        if target == .node(layout.root.id) {
            if let previous = navigation.beforeOverview {
                navigation.go(to: previous)
                navigation.beforeOverview = nil
            }
        } else {
            navigation.beforeOverview = navigation.current
            navigation.go(to: .overview)
        }
    }

    /// Fills the screen with `window`'s slot, or returns to the previous framing if it already does.
    public mutating func toggleMaximize(_ window: WindowID) {
        guard let g = layout.group(containing: window) else { return }
        let leaf = LayoutTarget.node(g.id)
        if target == leaf, let previous = navigation.beforeMaximize {
            navigation.go(to: previous)
            navigation.beforeMaximize = nil
            navigation.maximized = nil
        } else {
            navigation.beforeMaximize = navigation.current
            let framing = layout.framing(for: leaf)
            navigation.go(to: framing)
            navigation.maximized = framing
        }
    }

    /// Frames one node, such as a tile that was double-clicked.
    public mutating func frame(_ node: NodeID) {
        guard layout.root.contains(node) else { return }
        navigation.go(to: layout.framing(for: .node(node)))
    }

    public mutating func frame(_ target: LayoutTarget) {
        guard layout.contains(target) else { return }
        navigation.go(to: layout.framing(for: target))
    }

    /// Makes sure a window (or, for a floating window, the desktop) is on screen and big
    /// enough to use, widening the framing as little as possible. Without screen
    /// information it only widens.
    public mutating func reveal(_ window: WindowID, screen: Rect?, metrics: LayoutMetrics?, minSizes: [WindowID: Size] = [:]) {
        let leafID: NodeID
        if let g = layout.group(containing: window) {
            guard g.isPresent else { return }
            leafID = g.id
        } else if floating[window] != nil {
            leafID = layout.desktopID
        } else {
            return
        }
        let current = target
        var candidate = layout.widen(current, toInclude: leafID)
        if let screen, let metrics {
            // Zoom in from the widened framing until the window is big enough to use.
            var probe = candidate
            while !isUsable(window: window, leaf: leafID, target: probe, screen: screen, metrics: metrics, minSizes: minSizes) {
                let fractions = LayoutGeometry.rects(layout.root)
                guard let leafRect = fractions[leafID],
                      let next = layout.childTarget(of: probe, toward: leafRect.center, rects: fractions),
                      next != probe
                else { break }
                probe = next
            }
            candidate = probe
        }
        if candidate != current {
            navigation.go(to: layout.framing(for: candidate))
        }
    }

    private func isUsable(window: WindowID, leaf: NodeID, target: LayoutTarget, screen: Rect, metrics: LayoutMetrics, minSizes: [WindowID: Size]) -> Bool {
        let p = layout.presentation(target: target, screen: screen, metrics: metrics, minSizes: minSizes)
        if leaf == layout.desktopID { return p.desktopRect != nil }
        guard let active = layout.group(containing: window)?.activeWindow else { return false }
        return p.windowFrames[active] != nil
    }

    public mutating func back() { navigation.goBack() }
    public mutating func forward() { navigation.goForward() }

    public mutating func saveView(_ slot: Int) {
        guard (1...9).contains(slot) else { return }
        navigation.saved[String(slot)] = navigation.current
    }

    public mutating func recallView(_ slot: Int) {
        guard let framing = navigation.saved[String(slot)] else { return }
        navigation.go(to: framing)
    }

    // MARK: Docking

    /// What releasing `window` at screen point `p` would do.
    public func dropAction(for window: WindowID, at p: Point, presentation: Presentation, metrics: LayoutMetrics) -> DropAction {
        let wasDocked = isDocked(window)
        let fallback: DropAction = wasDocked ? .none : .float
        let ownGroup = layout.group(containing: window)
        let ownLoneGroup = ownGroup.flatMap { $0.presentWindows.count <= 1 ? $0.id : nil }
        let screen = presentation.screen

        // 1. The screen's edge docks beside everything the camera frames. The top band
        // is only the menu bar's edge, so title bars of the top row stay tab targets.
        var edges: [(Edge, Double)] = []
        let band = metrics.screenEdgeBand
        if p.x < screen.minX + band { edges.append((.left, p.x - screen.minX)) }
        if p.x > screen.maxX - band { edges.append((.right, screen.maxX - p.x)) }
        if p.y < screen.minY + min(band, 4) { edges.append((.top, p.y - screen.minY)) }
        if p.y > screen.maxY - band { edges.append((.bottom, screen.maxY - p.y)) }
        if let edge = edges.min(by: { $0.1 < $1.1 })?.0 {
            let target = presentation.target
            if case .node(let id) = target, id == ownLoneGroup { return .none }
            return .dock(target, edge)
        }

        // 2. A tile or docked window under the pointer.
        let leafCandidates = presentation.tiles.map { ($0.node, $0.rect, $0.kind) }
            + presentation.windowFrames.compactMap { w, _ -> (NodeID, Rect, Tile.Kind)? in
                guard let g = layout.group(containing: w), let r = presentation.nodeRects[g.id] else { return nil }
                return (g.id, r, .window(w))
            }
        for (node, rect, kind) in leafCandidates where rect.contains(p) {
            if node == ownLoneGroup { continue }
            switch kind {
            case .window:
                if p.y - rect.minY < metrics.titleZoneHeight {
                    return node == ownGroup?.id ? .none : .tab(node)
                }
                let band = min(max(metrics.edgeBandMin, metrics.edgeBandFraction * min(rect.width, rect.height)), metrics.edgeBandMax)
                let edge = rect.nearestEdge(to: p)
                if rect.distance(from: p, to: edge) < band { return .dock(.node(node), edge) }
                return fallback
            case .group, .desktop:
                let band = min(max(metrics.edgeBandMin, metrics.edgeBandFraction * min(rect.width, rect.height)), metrics.edgeBandMax)
                let edge = rect.nearestEdge(to: p)
                if rect.distance(from: p, to: edge) < band { return .dock(.node(node), edge) }
                return fallback
            }
        }

        // 3. The desktop: its edges dock beside it, its interior floats.
        if let desktop = presentation.desktopRect, desktop.contains(p) {
            let band = min(metrics.desktopBandMax, metrics.desktopBandFraction * min(desktop.width, desktop.height))
            let edge = desktop.nearestEdge(to: p)
            if desktop.distance(from: p, to: edge) < band { return .dock(.node(layout.desktopID), edge) }
            return .float
        }

        // 4. The gap between two neighbours inserts between them.
        if let divider = presentation.divider(at: p) {
            return .dock(.node(divider.before), divider.axis == .horizontal ? .right : .bottom)
        }

        return fallback
    }

    /// Applies a drop. `frame` is the window's frame where it was released.
    public mutating func applyDrop(_ action: DropAction, window: WindowID, frame: Rect, screen: Rect, metrics: LayoutMetrics) {
        switch action {
        case .none:
            return
        case .float:
            layout.remove(window)
            floating[window] = frame
        case .tab(let group):
            floating[window] = nil
            layout.addTab(window, to: group)
            reveal(window, screen: nil, metrics: nil)
        case .dock(let target, let edge):
            let share = dockShare(for: window, frame: frame, beside: target, edge: edge, screen: screen, metrics: metrics)
            floating[window] = nil
            layout.dock(window, beside: target, edge: edge, share: share)
            reveal(window, screen: nil, metrics: nil)
        }
    }

    /// Where `window` would end up if dropped with `action`: the frame to preview while dragging.
    public func previewFrame(for action: DropAction, window: WindowID, frame: Rect, screen: Rect, metrics: LayoutMetrics, minSizes: [WindowID: Size] = [:]) -> Rect? {
        switch action {
        case .none, .float:
            return nil
        case .tab, .dock:
            var copy = self
            copy.applyDrop(action, window: window, frame: frame, screen: screen, metrics: metrics)
            let p = copy.presentation(screen: screen, metrics: metrics, minSizes: minSizes)
            if let g = copy.layout.group(containing: window), let r = p.nodeRects[g.id] { return r }
            return nil
        }
    }

    /// How much of the target's space a newly docked window takes. Beside a single
    /// window it splits the space in half. Beside the desktop or a group it keeps
    /// roughly its current size, like a sidebar.
    private func dockShare(for window: WindowID, frame: Rect, beside target: LayoutTarget, edge: Edge, screen: Rect, metrics: LayoutMetrics) -> Double {
        let nodes = layout.nodes(of: target)
        if nodes.count == 1, case .group = nodes[0] { return 0.5 }
        let p = presentation(screen: screen, metrics: metrics)
        let rects = nodes.compactMap { p.nodeRects[$0.id] }
        guard let first = rects.first else { return 0.5 }
        let targetRect = rects.dropFirst().reduce(first) { $0.union($1) }
        let span = targetRect.span(along: edge.axis)
        guard span > 0 else { return 0.5 }
        return min(max(frame.span(along: edge.axis) / span, 0.2), 0.6)
    }

    /// Docks a floating window beside the desktop (to the right when the desktop is
    /// wider than tall, otherwise below), or floats a docked window at its last floating frame.
    public mutating func toggleFloat(_ window: WindowID, currentFrame: Rect, screen: Rect, metrics: LayoutMetrics) {
        if isDocked(window) {
            layout.remove(window)
            floating[window] = currentFrame
            reveal(window, screen: nil, metrics: nil)
        } else {
            let p = presentation(screen: screen, metrics: metrics)
            let desktop = p.nodeRects[layout.desktopID] ?? screen
            let edge: Edge = desktop.width >= desktop.height ? .right : .bottom
            applyDrop(.dock(.node(layout.desktopID), edge), window: window, frame: currentFrame, screen: screen, metrics: metrics)
        }
    }

    /// Docks every floating window (or those in `only`): each one splits the biggest slot
    /// on screen (a window or the desktop) along its longer side.
    public mutating func arrange(screen: Rect, metrics: LayoutMetrics, only: Set<WindowID>? = nil) {
        let windows = floating.filter { only?.contains($0.key) ?? true }.sorted { a, b in
            a.value.area != b.value.area ? a.value.area > b.value.area : a.key < b.key
        }
        guard !windows.isEmpty else { return }
        let before = target
        for (window, _) in windows {
            let fractions = LayoutGeometry.rects(layout.root)
            let leaves = layout.root.allNodes.filter { $0.isLeaf && $0.isPresent }
            func pixels(_ id: NodeID) -> Rect {
                let r = fractions[id] ?? .zero
                return Rect(x: r.x * screen.width, y: r.y * screen.height, width: r.width * screen.width, height: r.height * screen.height)
            }
            guard let biggest = leaves.max(by: { pixels($0.id).area < pixels($1.id).area }) else { break }
            let r = pixels(biggest.id)
            floating[window] = nil
            layout.dock(window, beside: .node(biggest.id), edge: r.width >= r.height ? .right : .bottom, share: 0.5)
        }
        // Keep the current framing, widened to show the newly docked windows.
        var t = layout.contains(before) ? before : .node(layout.root.id)
        for (window, _) in windows {
            if let g = layout.group(containing: window) { t = layout.widen(t, toInclude: g.id) }
        }
        navigation.go(to: layout.framing(for: t))
    }

    // MARK: Resizing

    /// Moves a divider so its centre sits at `position` (a screen coordinate along its axis).
    public mutating func moveDivider(_ divider: Divider, to position: Double, metrics: LayoutMetrics) {
        guard case .split(let s)? = layout.root.find(divider.split),
              let a = s.children.firstIndex(where: { $0.id == divider.before }),
              let b = s.children.firstIndex(where: { $0.id == divider.after })
        else { return }
        let span = divider.end - divider.start
        guard span > 0 else { return }
        let minimum = min(metrics.minimumSpan, span / 2 - 1)
        let clamped = min(max(position, divider.start + minimum), divider.end - minimum)
        let fraction = (clamped - divider.start) / span
        var weights = s.weights
        let total = weights[a] + weights[b]
        weights[a] = total * fraction
        weights[b] = total * (1 - fraction)
        layout.setWeights(of: s.id, weights)
    }

    /// A docked window was resized by its own border. Moves the dividers next to each
    /// edge that changed, so the layout follows the window instead of snapping it back.
    public mutating func resizeDocked(_ window: WindowID, from old: Rect, to new: Rect, presentation: Presentation, metrics: LayoutMetrics) {
        guard let g = layout.group(containing: window), let path = layout.root.path(to: g.id) else { return }
        let changes: [(Edge, Double)] = [
            (.left, new.minX - old.minX), (.right, new.maxX - old.maxX),
            (.top, new.minY - old.minY), (.bottom, new.maxY - old.maxY),
        ]
        for (edge, delta) in changes where abs(delta) > 2 {
            guard let divider = dividerBeside(path: path, edge: edge, presentation: presentation) else { continue }
            moveDivider(divider, to: divider.position + delta, metrics: metrics)
        }
    }

    /// The nearest divider on `edge` of the node at the end of `path`.
    private func dividerBeside(path: [NodeID], edge: Edge, presentation: Presentation) -> Divider? {
        for (ancestor, child) in zip(path, path.dropFirst()).reversed() {
            guard case .split(let s)? = layout.root.find(ancestor), s.axis == edge.axis else { continue }
            let present = s.presentIndices
            guard let i = present.firstIndex(where: { s.children[$0].id == child }) else { continue }
            let neighbour = edge.isLeading ? i - 1 : i + 1
            guard present.indices.contains(neighbour) else { continue }
            let before = s.children[present[min(i, neighbour)]].id
            let after = s.children[present[max(i, neighbour)]].id
            if let d = presentation.dividers.first(where: { $0.split == s.id && $0.before == before && $0.after == after }) {
                return d
            }
            guard let ra = presentation.nodeRects[before], let rb = presentation.nodeRects[after] else { return nil }
            let lo = ra.end(along: s.axis), hi = rb.start(along: s.axis)
            return Divider(split: s.id, before: before, after: after, axis: s.axis, hitRect: .zero,
                           start: ra.start(along: s.axis), end: rb.end(along: s.axis), position: (lo + hi) / 2)
        }
        return nil
    }

    // MARK: Focus

    /// The visible docked window nearest to `window` in a direction, for keyboard focus moves.
    public func neighbour(of window: WindowID, toward edge: Edge, presentation: Presentation) -> WindowID? {
        guard let from = presentation.windowFrames[window] else { return nil }
        var best: (WindowID, Double)?
        for (other, r) in presentation.windowFrames where other != window {
            let ahead: Bool
            let overlap: Double
            switch edge {
            case .left: ahead = r.maxX <= from.minX + 1; overlap = min(r.maxY, from.maxY) - max(r.minY, from.minY)
            case .right: ahead = r.minX >= from.maxX - 1; overlap = min(r.maxY, from.maxY) - max(r.minY, from.minY)
            case .top: ahead = r.maxY <= from.minY + 1; overlap = min(r.maxX, from.maxX) - max(r.minX, from.minX)
            case .bottom: ahead = r.minY >= from.maxY - 1; overlap = min(r.maxX, from.maxX) - max(r.minX, from.minX)
            }
            guard ahead else { continue }
            let dx = r.midX - from.midX, dy = r.midY - from.midY
            // Prefer windows that line up with this one, then the closest.
            let score = (dx * dx + dy * dy).squareRoot() - (overlap > 0 ? 10_000 : 0)
            if best == nil || score < best!.1 { best = (other, score) }
        }
        return best?.0
    }
}
