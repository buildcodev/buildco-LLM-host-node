import Foundation

/// A window, by its window server id (CGWindowID). It stays the same while the window is open.
public typealias WindowID = UInt32

/// What Espalier remembers about a window so it can find it again after a restart.
public struct WindowInfo: Codable, Hashable, Sendable {
    public var bundleID: String
    public var title: String

    public init(bundleID: String, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

/// Windows that share one frame under a strip of tabs. Only the active one is shown;
/// the others wait off screen until their tab is chosen.
public struct TabGroup: Codable, Equatable, Sendable {
    public var windows: [WindowID]
    public var active: WindowID
    /// Where the active window goes: whichever tab is shown takes this frame. The strip sits above it.
    public var frame: Rect

    public init(windows: [WindowID], active: WindowID, frame: Rect) {
        self.windows = windows
        self.active = active
        self.frame = frame
    }

    /// Tabs other than the active one.
    public var hidden: [WindowID] { windows.filter { $0 != active } }
}

/// Every tab group. A window is in at most one group, and a group always has two or more windows.
public struct TabGroups: Codable, Equatable, Sendable {
    public private(set) var groups: [TabGroup]

    public init(groups: [TabGroup] = []) {
        self.groups = []
        for g in groups { insert(g) }
    }

    public func group(containing window: WindowID) -> TabGroup? {
        groups.first { $0.windows.contains(window) }
    }

    public func isHidden(_ window: WindowID) -> Bool {
        group(containing: window).map { $0.active != window } ?? false
    }

    public var allWindows: Set<WindowID> {
        Set(groups.flatMap(\.windows))
    }

    /// Puts `window` in `target`'s group as its active tab, just after `target` (or at
    /// `index`). A lone `target` becomes a new group with `frame` as its frame. A window
    /// already in another group leaves it first.
    /// - Returns: the window that was shown in the group before and is now a hidden tab.
    @discardableResult
    public mutating func add(_ window: WindowID, to target: WindowID, frame: Rect, at index: Int? = nil) -> WindowID? {
        guard window != target else { return nil }
        if let i = groupIndex(of: target), groups[i].windows.contains(window) {
            // Already together: just move it and show it.
            var g = groups[i]
            g.windows.removeAll { $0 == window }
            g.windows.insert(window, at: insertionIndex(in: g, after: target, at: index))
            let previous = g.active
            g.active = window
            groups[i] = g
            return previous == window ? nil : previous
        }
        remove(window)
        if let i = groupIndex(of: target) {
            var g = groups[i]
            g.windows.insert(window, at: insertionIndex(in: g, after: target, at: index))
            let previous = g.active
            g.active = window
            groups[i] = g
            return previous
        }
        let ordered = index == 0 ? [window, target] : [target, window]
        groups.append(TabGroup(windows: ordered, active: window, frame: frame))
        return target
    }

    private func insertionIndex(in g: TabGroup, after target: WindowID, at index: Int?) -> Int {
        if let index { return min(max(index, 0), g.windows.count) }
        return (g.windows.firstIndex(of: target) ?? g.windows.count - 1) + 1
    }

    /// What taking a window out of its group changed.
    public struct Removal: Equatable, Sendable {
        /// The tab now shown in the group's frame, when the removed window was the one shown.
        public var shown: WindowID?
        /// The window left on its own when the group had only two tabs.
        public var dissolved: WindowID?
        /// The group's frame.
        public var frame: Rect
    }

    /// Takes `window` out of its group. When it was the tab being shown, its right-hand
    /// neighbour (or else its left) is shown instead. A group left with one window dissolves.
    @discardableResult
    public mutating func remove(_ window: WindowID) -> Removal? {
        guard let i = groupIndex(of: window) else { return nil }
        var g = groups[i]
        let position = g.windows.firstIndex(of: window)!
        g.windows.remove(at: position)
        var shown: WindowID?
        if g.active == window {
            g.active = g.windows[min(position, g.windows.count - 1)]
            shown = g.active
        }
        if g.windows.count < 2 {
            groups.remove(at: i)
            return Removal(shown: shown, dissolved: g.windows.first, frame: g.frame)
        }
        groups[i] = g
        return Removal(shown: shown, dissolved: nil, frame: g.frame)
    }

    /// Shows `window`'s tab. Returns the tab that was shown before, now hidden.
    @discardableResult
    public mutating func activate(_ window: WindowID) -> WindowID? {
        guard let i = groupIndex(of: window), groups[i].active != window else { return nil }
        let previous = groups[i].active
        groups[i].active = window
        return previous
    }

    /// The next (or previous) tab after `window`, wrapping around.
    public func neighbour(of window: WindowID, forward: Bool) -> WindowID? {
        guard let g = group(containing: window), let i = g.windows.firstIndex(of: window) else { return nil }
        let n = g.windows.count
        return g.windows[(i + (forward ? 1 : n - 1)) % n]
    }

    /// Moves a tab to `index` within its strip.
    public mutating func move(_ window: WindowID, to index: Int) {
        guard let i = groupIndex(of: window) else { return }
        var g = groups[i]
        g.windows.removeAll { $0 == window }
        g.windows.insert(window, at: min(max(index, 0), g.windows.count))
        groups[i] = g
    }

    /// Adds a whole group, such as one restored after a restart. Windows already in a group
    /// stay where they are; a group left with fewer than two windows isn't added.
    public mutating func adopt(_ group: TabGroup) {
        insert(group)
    }

    public mutating func setFrame(_ frame: Rect, ofGroupContaining window: WindowID) {
        guard let i = groupIndex(of: window) else { return }
        groups[i].frame = frame
    }

    /// Renames windows after a restart (saved id → live id) and drops the ones that are gone.
    public mutating func remap(_ mapping: [WindowID: WindowID]) {
        var remapped: [TabGroup] = []
        for var g in groups {
            g.windows = g.windows.compactMap { mapping[$0] }
            guard g.windows.count >= 2 else { continue }
            g.active = mapping[g.active].flatMap { g.windows.contains($0) ? $0 : nil } ?? g.windows[0]
            remapped.append(g)
        }
        groups = []
        for g in remapped { insert(g) }
    }

    private func groupIndex(of window: WindowID) -> Int? {
        groups.firstIndex { $0.windows.contains(window) }
    }

    /// Adds a group, dropping windows already in an earlier group and duplicates, so a
    /// hand-edited or stale file can't put a window in two places.
    private mutating func insert(_ group: TabGroup) {
        var g = group
        var seen = allWindows
        g.windows = g.windows.filter { seen.insert($0).inserted }
        guard g.windows.count >= 2 else { return }
        if !g.windows.contains(g.active) { g.active = g.windows[0] }
        groups.append(g)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(groups: try c.decodeIfPresent([TabGroup].self, forKey: .groups) ?? [])
    }
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
