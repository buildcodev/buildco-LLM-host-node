import Foundation

/// Something in the layout that can be docked beside or framed by the camera: a
/// single node, or a contiguous run of siblings inside one split.
public enum LayoutTarget: Hashable, Codable, Sendable {
    case node(NodeID)
    case siblings(split: NodeID, ids: [NodeID])
}

/// A display's docked layout: a tree of splits whose leaves are tab groups of
/// windows, plus the one desktop node that floating windows live on.
public struct Layout: Codable, Equatable, Sendable {
    public var root: LayoutNode

    public init(root: LayoutNode = .desktop(.make())) {
        self.root = root
        normalize()
    }

    private enum CodingKeys: String, CodingKey { case root }

    /// Saved layouts may have been edited by hand, so they're normalised on the way in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(root: try c.decode(LayoutNode.self, forKey: .root))
    }

    // MARK: Queries

    public var desktopID: NodeID {
        root.allNodes.first(where: \.isDesktop)?.id ?? root.id
    }

    public func group(containing window: WindowID) -> TabGroup? {
        root.group(containing: window)
    }

    public func isDocked(_ window: WindowID) -> Bool {
        group(containing: window) != nil
    }

    /// Docked windows that are currently present (not suspended).
    public var presentWindows: [WindowID] {
        root.allNodes.compactMap(\.asGroup).flatMap(\.presentWindows)
    }

    public var allWindows: [WindowID] { root.allWindows }

    // MARK: Editing

    /// Docks `window` beside `target`, taking `share` of the target's space along the
    /// edge's axis. If the window was already docked it's moved, not duplicated.
    public mutating func dock(_ window: WindowID, beside target: LayoutTarget, edge: Edge, share: Double = 0.5) {
        let share = min(max(share.isFinite ? share : 0.5, 0.05), 0.95)
        // Detach without normalizing, so the target can't be collapsed away underneath us.
        detach(window)
        let newNode = LayoutNode.group(TabGroup(windows: [window]))
        switch target {
        case .node(let id):
            insert(newNode, beside: root.contains(id) ? id : root.id, edge: edge, share: share)
        case .siblings(let splitID, let ids):
            insert(newNode, besideSiblings: ids, in: splitID, edge: edge, share: share)
        }
        normalize()
    }

    /// Adds `window` as a tab in `groupID`. If the group no longer exists, the window is docked beside the desktop instead.
    public mutating func addTab(_ window: WindowID, to groupID: NodeID, activate: Bool = true) {
        guard case .group = root.find(groupID) else {
            dock(window, beside: .node(desktopID), edge: .right)
            return
        }
        if group(containing: window)?.id == groupID {
            if activate { self.activate(window) }
            return
        }
        detach(window)
        root = root.mapGroups { g in
            guard g.id == groupID else { return g }
            var g = g
            g.slots.append(Slot(window: window))
            if activate { g.active = window }
            return g
        } ?? .desktop(.make())
        normalize()
    }

    /// Removes `window` from the layout. Its group closes if it was the last tab.
    public mutating func remove(_ window: WindowID) {
        detach(window)
        normalize()
    }

    public mutating func setSuspended(_ window: WindowID, _ suspended: Bool) {
        root = root.mapGroups { g in
            var g = g
            for i in g.slots.indices where g.slots[i].window == window {
                g.slots[i].suspended = suspended
            }
            return g
        } ?? root
    }

    /// Makes `window` the visible tab of its group.
    public mutating func activate(_ window: WindowID) {
        root = root.mapGroups { g in
            guard g.windows.contains(window) else { return g }
            var g = g
            g.active = window
            return g
        } ?? root
    }

    public mutating func setWeights(of splitID: NodeID, _ weights: [Double]) {
        root = root.replacing(splitID) { node in
            guard case .split(var s) = node, s.weights.count == weights.count else { return node }
            s.weights = weights
            return .split(s)
        } ?? root
    }

    /// Replaces window ids using `mapping`. Windows missing from the mapping are removed.
    public mutating func remap(_ mapping: [WindowID: WindowID]) {
        root = root.mapGroups { g in
            var g = g
            g.slots = g.slots.compactMap { slot in
                mapping[slot.window].map { Slot(window: $0, suspended: slot.suspended) }
            }
            g.active = g.active.flatMap { mapping[$0] }
            return g.slots.isEmpty ? nil : g
        } ?? .desktop(.make())
        normalize()
    }

    /// Restores the layout invariants: no empty groups, no single-child splits, no
    /// split directly inside a split on the same axis, positive weights, each window
    /// docked at most once, and exactly one desktop.
    public mutating func normalize() {
        var seen = Set<WindowID>()
        var deduped = root.mapGroups { g in
            var g = g
            g.slots = g.slots.filter { seen.insert($0.window).inserted }
            return g
        } ?? .desktop(.make())

        var sawDesktop = false
        deduped = Layout.removingExtraDesktops(deduped, sawDesktop: &sawDesktop) ?? .desktop(.make())

        var normalized = Layout.normalized(deduped) ?? .desktop(.make())
        if !normalized.containsDesktop {
            let wrapped = LayoutNode.split(Split(axis: .horizontal, children: [normalized, .desktop(.make())], weights: [1, 1]))
            normalized = Layout.normalized(wrapped) ?? wrapped
        }
        root = normalized
    }

    // MARK: Internals

    private mutating func detach(_ window: WindowID) {
        root = root.mapGroups { g in
            guard g.windows.contains(window) else { return g }
            var g = g
            g.slots.removeAll { $0.window == window }
            if g.active == window { g.active = g.slots.first?.window }
            return g.slots.isEmpty ? nil : g
        } ?? .desktop(.make())
    }

    private mutating func insert(_ new: LayoutNode, beside id: NodeID, edge: Edge, share: Double) {
        let pair: (_ children: [LayoutNode], _ weights: [Double]) -> Split = { children, weights in
            Split(axis: edge.axis, children: children, weights: weights)
        }
        if root.id == id {
            root = .split(edge.isLeading
                ? pair([new, root], [share, 1 - share])
                : pair([root, new], [1 - share, share]))
            return
        }
        guard let (parent, index) = root.parent(of: id) else { return }
        if parent.axis == edge.axis {
            root = root.replacing(parent.id) { node in
                guard case .split(var s) = node else { return node }
                let w = s.weights[index]
                s.weights[index] = w * (1 - share)
                let at = edge.isLeading ? index : index + 1
                s.children.insert(new, at: at)
                s.weights.insert(w * share, at: at)
                return .split(s)
            } ?? root
        } else {
            root = root.replacing(id) { node in
                .split(edge.isLeading
                    ? pair([new, node], [share, 1 - share])
                    : pair([node, new], [1 - share, share]))
            } ?? root
        }
    }

    private mutating func insert(_ new: LayoutNode, besideSiblings ids: [NodeID], in splitID: NodeID, edge: Edge, share: Double) {
        guard case .split(let s)? = root.find(splitID) else {
            insert(new, beside: root.id, edge: edge, share: share)
            return
        }
        let indices = ids.compactMap { id in s.children.firstIndex { $0.id == id } }.sorted()
        guard let lo = indices.first, let hi = indices.last else {
            insert(new, beside: splitID, edge: edge, share: share)
            return
        }
        if lo == 0 && hi == s.children.count - 1 {
            insert(new, beside: splitID, edge: edge, share: share)
            return
        }
        root = root.replacing(splitID) { node in
            guard case .split(var s) = node else { return node }
            let total = s.weights[lo...hi].reduce(0, +)
            if s.axis == edge.axis {
                for i in lo...hi { s.weights[i] *= (1 - share) }
                let at = edge.isLeading ? lo : hi + 1
                s.children.insert(new, at: at)
                s.weights.insert(total * share, at: at)
            } else {
                let inner = LayoutNode.split(Split(axis: s.axis, children: Array(s.children[lo...hi]), weights: Array(s.weights[lo...hi])))
                let outer = LayoutNode.split(Split(
                    axis: edge.axis,
                    children: edge.isLeading ? [new, inner] : [inner, new],
                    weights: edge.isLeading ? [share, 1 - share] : [1 - share, share]
                ))
                s.children.replaceSubrange(lo...hi, with: [outer])
                s.weights.replaceSubrange(lo...hi, with: [total])
            }
            return .split(s)
        } ?? root
    }

    private static func removingExtraDesktops(_ node: LayoutNode, sawDesktop: inout Bool) -> LayoutNode? {
        switch node {
        case .desktop:
            if sawDesktop { return nil }
            sawDesktop = true
            return node
        case .group:
            return node
        case .split(var s):
            var children: [LayoutNode] = []
            var weights: [Double] = []
            for (child, w) in zip(s.children, s.weights) {
                if let kept = removingExtraDesktops(child, sawDesktop: &sawDesktop) {
                    children.append(kept)
                    weights.append(w)
                }
            }
            s.children = children
            s.weights = weights
            return .split(s)
        }
    }

    private static func normalized(_ node: LayoutNode) -> LayoutNode? {
        switch node {
        case .desktop:
            return node
        case .group(var g):
            if g.slots.isEmpty { return nil }
            if let active = g.active, !g.windows.contains(active) { g.active = g.slots.first?.window }
            if g.active == nil { g.active = g.slots.first?.window }
            return .group(g)
        case .split(var s):
            var children: [LayoutNode] = []
            var weights: [Double] = []
            for (child, w) in zip(s.children, s.weights) {
                guard let n = normalized(child) else { continue }
                let weight = (w.isFinite && w > 0) ? w : 1
                if case .split(let inner) = n, inner.axis == s.axis {
                    let innerTotal = inner.weights.reduce(0, +)
                    for (c, iw) in zip(inner.children, inner.weights) {
                        children.append(c)
                        weights.append(weight * iw / innerTotal)
                    }
                } else {
                    children.append(n)
                    weights.append(weight)
                }
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            // Keep weights in a readable range: they sum to the number of children.
            let total = weights.reduce(0, +)
            s.weights = weights.map { $0 * Double(weights.count) / total }
            s.children = children
            return .split(s)
        }
    }
}
