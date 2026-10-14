import Foundation

/// A window's CGWindowID. Stable for the lifetime of the window, including across
/// restarts of Espalier itself.
public typealias WindowID = UInt32

public struct NodeID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static func make() -> NodeID {
        NodeID(String(UUID().uuidString.prefix(8)).lowercased())
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// One window in a tab group. A suspended window (minimized, its app hidden, or on
/// another Space) keeps its slot so it comes back to the same place, but takes
/// no room in the layout while it's away.
public struct Slot: Codable, Equatable, Sendable {
    public var window: WindowID
    public var suspended: Bool

    public init(window: WindowID, suspended: Bool = false) {
        self.window = window
        self.suspended = suspended
    }
}

/// A leaf of the layout: one or more windows stacked as tabs in the same space.
public struct TabGroup: Codable, Equatable, Sendable {
    public var id: NodeID
    public var slots: [Slot]
    public var active: WindowID?

    public init(id: NodeID = .make(), windows: [WindowID], active: WindowID? = nil) {
        self.id = id
        self.slots = windows.map { Slot(window: $0) }
        self.active = active ?? windows.first
    }

    public var windows: [WindowID] { slots.map(\.window) }
    public var presentWindows: [WindowID] { slots.filter { !$0.suspended }.map(\.window) }
    public var isPresent: Bool { slots.contains { !$0.suspended } }

    /// The tab that's showing: the chosen one if it's present, otherwise the first present tab.
    public var activeWindow: WindowID? {
        let present = presentWindows
        if let active, present.contains(active) { return active }
        return present.first
    }
}

/// A weighted row or column.
public struct Split: Codable, Equatable, Sendable {
    public var id: NodeID
    public var axis: Axis
    public var children: [LayoutNode]
    public var weights: [Double]

    public init(id: NodeID = .make(), axis: Axis, children: [LayoutNode], weights: [Double]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        self.weights = weights ?? Array(repeating: 1, count: children.count)
    }

    public var presentIndices: [Int] { children.indices.filter { children[$0].isPresent } }
}

public indirect enum LayoutNode: Equatable, Sendable {
    /// The desktop that floating windows live on. A layout has exactly one, and it never collapses.
    case desktop(NodeID)
    case group(TabGroup)
    case split(Split)

    public var id: NodeID {
        switch self {
        case .desktop(let id): return id
        case .group(let g): return g.id
        case .split(let s): return s.id
        }
    }

    public var isPresent: Bool {
        switch self {
        case .desktop: return true
        case .group(let g): return g.isPresent
        case .split(let s): return s.children.contains { $0.isPresent }
        }
    }

    public var isLeaf: Bool {
        if case .split = self { return false }
        return true
    }

    public var isDesktop: Bool {
        if case .desktop = self { return true }
        return false
    }

    public var asGroup: TabGroup? {
        if case .group(let g) = self { return g }
        return nil
    }

    public var asSplit: Split? {
        if case .split(let s) = self { return s }
        return nil
    }

    public var children: [LayoutNode] {
        if case .split(let s) = self { return s.children }
        return []
    }

    /// Every window in this subtree, suspended or not, in tree order.
    public var allWindows: [WindowID] {
        switch self {
        case .desktop: return []
        case .group(let g): return g.windows
        case .split(let s): return s.children.flatMap(\.allWindows)
        }
    }

    public var containsDesktop: Bool {
        switch self {
        case .desktop: return true
        case .group: return false
        case .split(let s): return s.children.contains { $0.containsDesktop }
        }
    }

    /// Every node in this subtree, depth first, parents before children.
    public var allNodes: [LayoutNode] {
        [self] + children.flatMap(\.allNodes)
    }

    public func find(_ id: NodeID) -> LayoutNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    public func contains(_ id: NodeID) -> Bool { find(id) != nil }

    /// The group holding `window`, if it's docked in this subtree.
    public func group(containing window: WindowID) -> TabGroup? {
        switch self {
        case .desktop: return nil
        case .group(let g): return g.windows.contains(window) ? g : nil
        case .split(let s):
            for child in s.children {
                if let g = child.group(containing: window) { return g }
            }
            return nil
        }
    }

    /// The split that directly contains `id`, and the child's index in it.
    public func parent(of id: NodeID) -> (split: Split, index: Int)? {
        guard case .split(let s) = self else { return nil }
        if let i = s.children.firstIndex(where: { $0.id == id }) { return (s, i) }
        for child in s.children {
            if let found = child.parent(of: id) { return found }
        }
        return nil
    }

    /// The ids from this node down to `id`, inclusive, or nil when `id` isn't in the subtree.
    public func path(to id: NodeID) -> [NodeID]? {
        if self.id == id { return [id] }
        for child in children {
            if let rest = child.path(to: id) { return [self.id] + rest }
        }
        return nil
    }

    /// Returns a copy with the node `id` replaced by `transform(node)`.
    /// A nil result from `transform` removes the node; a split's weight is removed with it.
    public func replacing(_ id: NodeID, with transform: (LayoutNode) -> LayoutNode?) -> LayoutNode? {
        if self.id == id { return transform(self) }
        guard case .split(var s) = self else { return self }
        var children: [LayoutNode] = []
        var weights: [Double] = []
        for (child, weight) in zip(s.children, s.weights) {
            if let replaced = child.replacing(id, with: transform) {
                children.append(replaced)
                weights.append(weight)
            }
        }
        s.children = children
        s.weights = weights
        return .split(s)
    }

    /// Applies `transform` to every group in the subtree. Returning nil removes the group.
    public func mapGroups(_ transform: (TabGroup) -> TabGroup?) -> LayoutNode? {
        switch self {
        case .desktop: return self
        case .group(let g): return transform(g).map { .group($0) }
        case .split(var s):
            var children: [LayoutNode] = []
            var weights: [Double] = []
            for (child, weight) in zip(s.children, s.weights) {
                if let mapped = child.mapGroups(transform) {
                    children.append(mapped)
                    weights.append(weight)
                }
            }
            s.children = children
            s.weights = weights
            return .split(s)
        }
    }
}

// MARK: - Codable

extension LayoutNode: Codable {
    private enum Kind: String, Codable {
        case desktop, group, split
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, slots, active, axis, children, weights
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(NodeID.self, forKey: .id)
        switch try c.decode(Kind.self, forKey: .type) {
        case .desktop:
            self = .desktop(id)
        case .group:
            var g = TabGroup(id: id, windows: [])
            g.slots = try c.decode([Slot].self, forKey: .slots)
            g.active = try c.decodeIfPresent(WindowID.self, forKey: .active)
            self = .group(g)
        case .split:
            let children = try c.decode([LayoutNode].self, forKey: .children)
            var weights = try c.decodeIfPresent([Double].self, forKey: .weights) ?? []
            if weights.count != children.count { weights = Array(repeating: 1, count: children.count) }
            self = .split(Split(id: id, axis: try c.decode(Axis.self, forKey: .axis), children: children, weights: weights))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch self {
        case .desktop:
            try c.encode(Kind.desktop, forKey: .type)
        case .group(let g):
            try c.encode(Kind.group, forKey: .type)
            try c.encode(g.slots, forKey: .slots)
            try c.encodeIfPresent(g.active, forKey: .active)
        case .split(let s):
            try c.encode(Kind.split, forKey: .type)
            try c.encode(s.axis, forKey: .axis)
            try c.encode(s.weights, forKey: .weights)
            try c.encode(s.children, forKey: .children)
        }
    }
}
