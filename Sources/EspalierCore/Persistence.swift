import Foundation

/// Everything Espalier saves between runs, in `state.json`.
public struct TabsSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var tabs: TabGroups
    /// Each grouped window's app and title, to find it again after a restart.
    public var windowInfo: [WindowID: WindowInfo]
    /// The narrowest each app's windows will go (by bundle id), learned from windows that
    /// refused to shrink. Used to widen a side before the app has to refuse again.
    public var minimumWidths: [String: Double]

    public init(tabs: TabGroups = TabGroups(), windowInfo: [WindowID: WindowInfo] = [:], minimumWidths: [String: Double] = [:]) {
        self.version = TabsSnapshot.currentVersion
        self.tabs = tabs
        self.windowInfo = windowInfo
        self.minimumWidths = minimumWidths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        tabs = try c.decodeIfPresent(TabGroups.self, forKey: .tabs) ?? TabGroups()
        windowInfo = try c.decodeIfPresent([WindowID: WindowInfo].self, forKey: .windowInfo) ?? [:]
        minimumWidths = try c.decodeIfPresent([String: Double].self, forKey: .minimumWidths) ?? [:]
    }

    public static func decode(_ data: Data) throws -> TabsSnapshot {
        let snapshot = try JSONDecoder().decode(TabsSnapshot.self, from: data)
        guard snapshot.version <= currentVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Saved by a newer version of Espalier (\(snapshot.version))"))
        }
        return snapshot
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Finds saved windows among live ones after a restart.
public enum WindowMatcher {
    /// Returns saved id → live id. A window keeps its CGWindowID while it's open, so a
    /// restart of Espalier matches exactly. When an app relaunched, windows are matched by
    /// app and title, then by app alone, in id order.
    public static func match(saved: [WindowID: WindowInfo], live: [WindowID: WindowInfo]) -> [WindowID: WindowID] {
        var result: [WindowID: WindowID] = [:]
        var unclaimed = Set(live.keys)

        for (id, info) in saved where live[id]?.bundleID == info.bundleID {
            result[id] = id
            unclaimed.remove(id)
        }
        let remaining = { saved.keys.filter { result[$0] == nil }.sorted() }
        for id in remaining() {
            let info = saved[id]!
            if let hit = unclaimed.sorted().first(where: { live[$0]! == info }) {
                result[id] = hit
                unclaimed.remove(hit)
            }
        }
        for id in remaining() {
            let info = saved[id]!
            if let hit = unclaimed.sorted().first(where: { live[$0]!.bundleID == info.bundleID }) {
                result[id] = hit
                unclaimed.remove(hit)
            }
        }
        return result
    }
}
