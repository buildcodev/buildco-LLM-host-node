import Foundation

/// Everything Espalier saves between runs: one `DisplayState` per display, keyed by the display's UUID.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var displays: [String: DisplayState]

    public init(displays: [String: DisplayState] = [:]) {
        self.version = WorkspaceSnapshot.currentVersion
        self.displays = displays
    }

    public static func decode(_ data: Data) throws -> WorkspaceSnapshot {
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
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
