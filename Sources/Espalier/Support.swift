#if os(macOS)
import AppKit
import EspalierCore
import os

// AppKit also exports the legacy MacTypes `Point`, `Rect` and `Size`. Declarations in this
// module shadow imported ones, so these make the layout engine's types the default here.
typealias Rect = EspalierCore.Rect
typealias Point = EspalierCore.Point
typealias Size = EspalierCore.Size
typealias Edge = EspalierCore.Edge

let logger = Logger(subsystem: "dev.buildco.espalier", category: "espalier")

extension EspalierCore.Rect {
    init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension EspalierCore.Point {
    init(_ p: CGPoint) {
        self.init(x: Double(p.x), y: Double(p.y))
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension EspalierCore.Size {
    init(_ s: CGSize) {
        self.init(width: Double(s.width), height: Double(s.height))
    }
}

/// Runs a closure at most once, from whichever caller gets there first.
final class Once: @unchecked Sendable {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func fire() {
        let a = action
        action = nil
        a?()
    }
}
#endif
