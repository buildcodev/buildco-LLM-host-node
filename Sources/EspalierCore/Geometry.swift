import Foundation

// All geometry uses a top-left origin with y growing downwards. That matches the
// Accessibility API's global coordinate space, so screen rects from the core can
// be handed to AX without flipping.

public struct Point: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func coordinate(along axis: Axis) -> Double {
        axis == .horizontal ? x : y
    }
}

public struct Size: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)

    public func span(along axis: Axis) -> Double {
        axis == .horizontal ? width : height
    }

    /// True when both dimensions are at least as large as `other`'s.
    public func fits(_ other: Size) -> Bool {
        width + 0.5 >= other.width && height + 0.5 >= other.height
    }
}

public struct Rect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let unit = Rect(x: 0, y: 0, width: 1, height: 1)
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var center: Point { Point(x: midX, y: midY) }
    public var origin: Point { Point(x: x, y: y) }
    public var size: Size { Size(width: width, height: height) }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var description: String {
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        return "(\(f(x)), \(f(y)), \(f(width))×\(f(height)))"
    }

    public func start(along axis: Axis) -> Double { axis == .horizontal ? minX : minY }
    public func end(along axis: Axis) -> Double { axis == .horizontal ? maxX : maxY }
    public func span(along axis: Axis) -> Double { axis == .horizontal ? width : height }

    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func contains(_ r: Rect, tolerance: Double = 0) -> Bool {
        r.minX >= minX - tolerance && r.maxX <= maxX + tolerance
            && r.minY >= minY - tolerance && r.maxY <= maxY + tolerance
    }

    public func intersection(_ r: Rect) -> Rect {
        let x0 = max(minX, r.minX), y0 = max(minY, r.minY)
        let x1 = min(maxX, r.maxX), y1 = min(maxY, r.maxY)
        if x1 <= x0 || y1 <= y0 { return .zero }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Overlap with positive area. Rects that only share an edge don't overlap.
    public func overlaps(_ r: Rect, epsilon: Double = 1e-9) -> Bool {
        let i = intersection(r)
        return i.width > epsilon && i.height > epsilon
    }

    public func union(_ r: Rect) -> Rect {
        let x0 = min(minX, r.minX), y0 = min(minY, r.minY)
        let x1 = max(maxX, r.maxX), y1 = max(maxY, r.maxY)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }

    public func inset(_ d: Double) -> Rect { insetBy(dx: d, dy: d) }

    /// Distance from `p` to each edge, measured inwards. Negative when `p` is outside that edge.
    public func distance(from p: Point, to edge: Edge) -> Double {
        switch edge {
        case .left: return p.x - minX
        case .right: return maxX - p.x
        case .top: return p.y - minY
        case .bottom: return maxY - p.y
        }
    }

    /// The edge closest to `p`, comparing distances relative to the rect's size so
    /// long thin rects don't always pick their long sides.
    public func nearestEdge(to p: Point) -> Edge {
        var best = Edge.left
        var bestScore = Double.infinity
        for edge in Edge.allCases {
            let span = max(1e-9, edge.axis == .horizontal ? width : height)
            let score = distance(from: p, to: edge) / span
            if score < bestScore {
                bestScore = score
                best = edge
            }
        }
        return best
    }

    /// Linear interpolation between two rects.
    public func interpolated(to other: Rect, t: Double) -> Rect {
        Rect(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t,
            width: width + (other.width - width) * t,
            height: height + (other.height - height) * t
        )
    }

    /// Moves (and if needed shrinks) the rect so it lies inside `bounds`.
    public func clamped(into bounds: Rect) -> Rect {
        let w = min(width, bounds.width)
        let h = min(height, bounds.height)
        return Rect(
            x: min(max(x, bounds.minX), bounds.maxX - w),
            y: min(max(y, bounds.minY), bounds.maxY - h),
            width: w,
            height: h
        )
    }

    /// Maps a rect positioned relative to `from` onto the same relative position in `to`.
    public func mapped(from: Rect, to: Rect) -> Rect {
        let sx = to.width / max(from.width, 1e-12)
        let sy = to.height / max(from.height, 1e-12)
        return Rect(x: to.x + (x - from.x) * sx, y: to.y + (y - from.y) * sy, width: width * sx, height: height * sy)
    }

    public func isApproximatelyEqual(to other: Rect, tolerance: Double = 0.5) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    /// Splits the rect along `axis` in proportion to `weights`.
    public func divided(along axis: Axis, weights: [Double]) -> [Rect] {
        let total = weights.reduce(0, +)
        guard total > 0 else { return weights.map { _ in self } }
        var result: [Rect] = []
        var cursor = start(along: axis)
        let span = span(along: axis)
        for (i, w) in weights.enumerated() {
            // The last child absorbs rounding so the pieces tile exactly.
            let length = i == weights.count - 1 ? end(along: axis) - cursor : span * w / total
            if axis == .horizontal {
                result.append(Rect(x: cursor, y: y, width: length, height: height))
            } else {
                result.append(Rect(x: x, y: cursor, width: width, height: length))
            }
            cursor += length
        }
        return result
    }
}

/// `horizontal` lays children out left to right (a row), `vertical` top to bottom (a column).
public enum Axis: String, Codable, Sendable, CaseIterable {
    case horizontal
    case vertical

    public var other: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Edge: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case top
    case bottom

    /// The axis a split needs to place something beside this edge.
    public var axis: Axis { (self == .left || self == .right) ? .horizontal : .vertical }

    /// Left and top come before the target in a split; right and bottom come after.
    public var isLeading: Bool { self == .left || self == .top }

    public var opposite: Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }
}

/// A screen line segment, used to draw the splits inside a collapsed group tile.
public struct LineSegment: Hashable, Codable, Sendable {
    public var from: Point
    public var to: Point

    public init(from: Point, to: Point) {
        self.from = from
        self.to = to
    }
}
