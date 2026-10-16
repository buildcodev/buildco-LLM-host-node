import Foundation

/// Fractional layout: every present node's rect inside the unit square ("world"
/// coordinates). The camera then maps part of that world onto a screen.
public enum LayoutGeometry {
    public static func rects(_ root: LayoutNode, in bounds: Rect = .unit) -> [NodeID: Rect] {
        var result: [NodeID: Rect] = [:]
        assign(root, bounds, into: &result)
        return result
    }

    private static func assign(_ node: LayoutNode, _ bounds: Rect, into result: inout [NodeID: Rect]) {
        guard node.isPresent else { return }
        result[node.id] = bounds
        guard case .split(let s) = node else { return }
        let present = s.presentIndices
        let pieces = bounds.divided(along: s.axis, weights: present.map { s.weights[$0] })
        for (i, rect) in zip(present, pieces) {
            assign(s.children[i], rect, into: &result)
        }
    }
}

public enum Camera {
    /// Maps a world rect to the screen, given the world rect the camera shows and the screen rect it fills.
    public static func map(_ r: Rect, world: Rect, onto screen: Rect) -> Rect {
        let sx = screen.width / max(world.width, 1e-12)
        let sy = screen.height / max(world.height, 1e-12)
        return Rect(
            x: screen.x + (r.x - world.x) * sx,
            y: screen.y + (r.y - world.y) * sy,
            width: r.width * sx,
            height: r.height * sy
        )
    }

    /// The inverse of `map` for a point: screen to world.
    public static func unmap(_ p: Point, world: Rect, from screen: Rect) -> Point {
        Point(
            x: world.x + (p.x - screen.x) / max(screen.width, 1e-12) * world.width,
            y: world.y + (p.y - screen.y) / max(screen.height, 1e-12) * world.height
        )
    }

    /// Interpolates between two camera rects. The centre moves linearly and the size
    /// changes geometrically, so a big zoom feels even all the way through.
    public static func interpolate(from a: Rect, to b: Rect, t: Double) -> Rect {
        let t = min(max(t, 0), 1)
        func geo(_ x: Double, _ y: Double) -> Double {
            guard x > 0, y > 0 else { return x + (y - x) * t }
            return x * pow(y / x, t)
        }
        let w = geo(a.width, b.width)
        let h = geo(a.height, b.height)
        let cx = a.midX + (b.midX - a.midX) * t
        let cy = a.midY + (b.midY - a.midY) * t
        return Rect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

/// What the camera shows, stored as *which windows* are framed rather than which
/// node, so history and saved views survive the layout being edited.
public struct Framing: Codable, Hashable, Sendable {
    public var windows: Set<WindowID>
    public var desktop: Bool
    public var overview: Bool

    public init(windows: Set<WindowID> = [], desktop: Bool = false, overview: Bool = false) {
        self.windows = windows
        self.desktop = desktop
        self.overview = overview
    }

    public static let overview = Framing(overview: true)
}

extension Layout {
    /// The node or sibling range that best matches `framing`: the smallest one that
    /// contains everything the framing names. Windows that no longer exist are ignored,
    /// and a framing with nothing left resolves to the whole layout.
    public func resolve(_ framing: Framing) -> LayoutTarget {
        if framing.overview { return .node(root.id) }
        var leaves = Set<NodeID>()
        for window in framing.windows {
            if let g = group(containing: window), g.isPresent { leaves.insert(g.id) }
        }
        if framing.desktop { leaves.insert(desktopID) }
        if leaves.isEmpty { return .node(root.id) }
        return lowestTarget(containing: leaves)
    }

    /// The framing that names everything inside `target`.
    public func framing(for target: LayoutTarget) -> Framing {
        if target == .node(root.id) { return .overview }
        let nodes = self.nodes(of: target)
        if nodes.isEmpty { return .overview }
        return Framing(
            windows: Set(nodes.flatMap(\.allWindows)),
            desktop: nodes.contains { $0.containsDesktop }
        )
    }

    public func nodes(of target: LayoutTarget) -> [LayoutNode] {
        switch target {
        case .node(let id):
            return root.find(id).map { [$0] } ?? []
        case .siblings(let splitID, let ids):
            guard case .split(let s)? = root.find(splitID) else { return [] }
            return s.children.filter { ids.contains($0.id) }
        }
    }

    public func contains(_ target: LayoutTarget) -> Bool {
        !nodes(of: target).isEmpty
    }

    /// The world rect of a target, given the fractional rects of the layout.
    public func worldRect(for target: LayoutTarget, rects: [NodeID: Rect]) -> Rect {
        let nodeRects = nodes(of: target).compactMap { rects[$0.id] }
        guard let first = nodeRects.first else { return .unit }
        return nodeRects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// One level up from `target`, or nil at the top. Ancestors that only hold the
    /// target (their other children are suspended) are skipped, since framing them
    /// would look identical.
    public func parentTarget(of target: LayoutTarget) -> LayoutTarget? {
        switch target {
        case .siblings(let splitID, _):
            return root.contains(splitID) ? .node(splitID) : .node(root.id)
        case .node(let id):
            var current = id
            while let (parent, _) = root.parent(of: current) {
                if parent.presentIndices.count > 1 { return .node(parent.id) }
                current = parent.id
            }
            return nil
        }
    }

    /// One level down from `target`, towards the world point `p`, or nil when the target is a single leaf.
    public func childTarget(of target: LayoutTarget, toward p: Point, rects: [NodeID: Rect]) -> LayoutTarget? {
        var candidates: [LayoutNode]
        switch target {
        case .node(let id):
            guard case .split(let s)? = root.find(id) else { return nil }
            candidates = s.presentIndices.map { s.children[$0] }
        case .siblings(let splitID, let ids):
            guard case .split(let s)? = root.find(splitID) else { return nil }
            candidates = s.presentIndices.map { s.children[$0] }.filter { ids.contains($0.id) }
        }
        candidates = candidates.filter { rects[$0.id] != nil }
        guard !candidates.isEmpty else { return nil }
        var chosen = candidates.first { rects[$0.id]!.contains(p) } ?? candidates.min { a, b in
            distanceSquared(rects[a.id]!.center, p) < distanceSquared(rects[b.id]!.center, p)
        }!
        // Skip splits that only show one child: framing them looks the same as framing the child.
        while case .split(let s) = chosen, s.presentIndices.count == 1 {
            chosen = s.children[s.presentIndices[0]]
        }
        return .node(chosen.id)
    }

    /// The target that frames `leafID` together with everything in `target`.
    public func widen(_ target: LayoutTarget, toInclude leafID: NodeID) -> LayoutTarget {
        var leaves = Set(nodes(of: target).flatMap { $0.allNodes.filter(\.isLeaf).filter(\.isPresent).map(\.id) })
        leaves.insert(leafID)
        return lowestTarget(containing: leaves)
    }

    /// The leaf ids inside a target.
    public func leafIDs(of target: LayoutTarget) -> Set<NodeID> {
        Set(nodes(of: target).flatMap { $0.allNodes.filter(\.isLeaf).map(\.id) })
    }

    private func lowestTarget(containing leaves: Set<NodeID>) -> LayoutTarget {
        var node = root
        while case .split(let s) = node {
            let present = s.presentIndices
            let hits = present.filter { i in
                s.children[i].allNodes.contains { leaves.contains($0.id) }
            }
            if hits.count == 1 {
                node = s.children[hits[0]]
                continue
            }
            guard let first = hits.first, let last = hits.last,
                  let lo = present.firstIndex(of: first), let hi = present.firstIndex(of: last)
            else { break }
            let range = Array(present[lo...hi])
            if range.count == present.count { return .node(s.id) }
            return .siblings(split: s.id, ids: range.map { s.children[$0].id })
        }
        return .node(node.id)
    }

    private func distanceSquared(_ a: Point, _ b: Point) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }
}

/// Camera history and saved views for one display.
public struct Navigation: Codable, Equatable, Sendable {
    public var current: Framing = .overview
    public var back: [Framing] = []
    public var forward: [Framing] = []
    /// Where the overview toggle returns to.
    public var beforeOverview: Framing?
    /// Where toggling a maximized window returns to, and which framing that toggle produced.
    public var beforeMaximize: Framing?
    public var maximized: Framing?
    /// Saved views, keyed "1" through "9".
    public var saved: [String: Framing] = [:]

    public static let historyLimit = 50

    public init() {}

    /// Moves the camera, recording the previous framing in history.
    public mutating func go(to framing: Framing) {
        guard framing != current else { return }
        back.append(current)
        if back.count > Navigation.historyLimit { back.removeFirst(back.count - Navigation.historyLimit) }
        forward.removeAll()
        current = framing
        if framing != maximized { maximized = nil }
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let previous = back.popLast() else { return false }
        forward.append(current)
        current = previous
        return true
    }

    @discardableResult
    public mutating func goForward() -> Bool {
        guard let next = forward.popLast() else { return false }
        back.append(current)
        current = next
        return true
    }

    /// Drops windows that no longer exist from every stored framing.
    public mutating func prune(keeping live: Set<WindowID>) {
        func clean(_ f: Framing) -> Framing {
            var f = f
            f.windows.formIntersection(live)
            return f
        }
        current = clean(current)
        back = back.map(clean)
        forward = forward.map(clean)
        beforeOverview = beforeOverview.map(clean)
        beforeMaximize = beforeMaximize.map(clean)
        maximized = maximized.map(clean)
        saved = saved.mapValues(clean).filter { !$0.value.windows.isEmpty || $0.value.desktop || $0.value.overview }
    }

    public mutating func remap(_ mapping: [WindowID: WindowID]) {
        func map(_ f: Framing) -> Framing {
            var f = f
            f.windows = Set(f.windows.compactMap { mapping[$0] })
            return f
        }
        current = map(current)
        back = back.map(map)
        forward = forward.map(map)
        beforeOverview = beforeOverview.map(map)
        beforeMaximize = beforeMaximize.map(map)
        maximized = maximized.map(map)
        saved = saved.mapValues(map)
    }
}
