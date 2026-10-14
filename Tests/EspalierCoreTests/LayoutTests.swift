import XCTest
@testable import EspalierCore

/// Helpers for building layouts in tests.
enum Fixture {
    static let screen = Rect(x: 0, y: 25, width: 1600, height: 1000)
    static var metrics: LayoutMetrics {
        var m = LayoutMetrics()
        m.gap = 0
        m.margin = 0
        return m
    }

    /// desktop | 1, with 1 split vertically into 1 / 2.
    static func threeWay() -> DisplayState {
        var s = DisplayState()
        s.layout.dock(1, beside: .node(s.layout.desktopID), edge: .right, share: 0.5)
        s.layout.dock(2, beside: .node(s.layout.group(containing: 1)!.id), edge: .bottom, share: 0.5)
        return s
    }
}

extension Layout {
    /// A compact description: D for the desktop, window ids for groups, row(...) and col(...).
    var shape: String { Layout.shape(root) }

    static func shape(_ node: LayoutNode) -> String {
        switch node {
        case .desktop: return "D"
        case .group(let g): return g.windows.map(String.init).joined(separator: "+")
        case .split(let s):
            let inner = s.children.map(shape).joined(separator: ",")
            return (s.axis == .horizontal ? "row(" : "col(") + inner + ")"
        }
    }
}

final class LayoutTests: XCTestCase {
    func testNewLayoutIsJustTheDesktop() {
        let layout = Layout()
        XCTAssertEqual(layout.shape, "D")
        XCTAssertTrue(layout.root.isDesktop)
    }

    func testDockBesideDesktopCreatesRow() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .left, share: 0.3)
        XCTAssertEqual(layout.shape, "row(1,D)")
        guard case .split(let s) = layout.root else { return XCTFail() }
        XCTAssertEqual(s.weights[0] / (s.weights[0] + s.weights[1]), 0.3, accuracy: 1e-9)
    }

    func testDockingAlongTheSameAxisInsertsASibling() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .right)
        XCTAssertEqual(layout.shape, "row(D,1,2)")
    }

    func testDockingAcrossTheAxisNests() {
        let s = Fixture.threeWay()
        XCTAssertEqual(s.layout.shape, "row(D,col(1,2))")
        var layout = s.layout
        layout.dock(3, beside: .node(layout.group(containing: 2)!.id), edge: .left)
        XCTAssertEqual(layout.shape, "row(D,col(1,row(3,2)))")
    }

    func testDockingBesideTheRootWrapsIt() {
        var layout = Fixture.threeWay().layout
        layout.dock(9, beside: .node(layout.root.id), edge: .top, share: 0.25)
        XCTAssertEqual(layout.shape, "col(9,row(D,col(1,2)))")
    }

    func testRemovingCollapsesSingleChildSplits() {
        var layout = Fixture.threeWay().layout
        layout.remove(2)
        XCTAssertEqual(layout.shape, "row(D,1)")
        layout.remove(1)
        XCTAssertEqual(layout.shape, "D")
    }

    func testRemovingFlattensSameAxisSplits() {
        var layout = Fixture.threeWay().layout
        // row(D, col(1, row(3, 2))) → removing 1 leaves row(D, row(3, 2)) → row(D, 3, 2)
        layout.dock(3, beside: .node(layout.group(containing: 2)!.id), edge: .left)
        layout.remove(1)
        XCTAssertEqual(layout.shape, "row(D,3,2)")
    }

    func testFlatteningPreservesProportions() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right, share: 0.5)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .bottom)
        layout.dock(3, beside: .node(layout.group(containing: 2)!.id), edge: .right)
        let before = LayoutGeometry.rects(layout.root)
        let r3 = before[layout.group(containing: 3)!.id]!
        layout.remove(1)
        let after = LayoutGeometry.rects(layout.root)
        let r3After = after[layout.group(containing: 3)!.id]!
        XCTAssertEqual(layout.shape, "row(D,2,3)")
        XCTAssertEqual(r3.width, r3After.width, accuracy: 1e-9)
        XCTAssertEqual(r3.maxX, r3After.maxX, accuracy: 1e-9)
    }

    func testMovingADockedWindowDoesNotDuplicateIt() {
        var layout = Fixture.threeWay().layout
        layout.dock(2, beside: .node(layout.desktopID), edge: .left)
        XCTAssertEqual(layout.shape, "row(2,D,1)")
        XCTAssertEqual(layout.allWindows.sorted(), [1, 2])
    }

    func testDockingBesideAGroupThatCollapsesDuringTheMoveStillWorks() {
        // col(1, 2) beside the desktop; dock 1 to the right of the col(1, 2) split itself.
        var layout = Fixture.threeWay().layout
        guard case .split(let row) = layout.root, case .split(let col) = row.children[1] else { return XCTFail() }
        layout.dock(1, beside: .node(col.id), edge: .right)
        XCTAssertEqual(layout.shape, "row(D,2,1)")
    }

    func testTabs() {
        var layout = Fixture.threeWay().layout
        let g1 = layout.group(containing: 1)!.id
        layout.addTab(5, to: g1)
        XCTAssertEqual(layout.shape, "row(D,col(1+5,2))")
        XCTAssertEqual(layout.group(containing: 5)?.activeWindow, 5)
        layout.activate(1)
        XCTAssertEqual(layout.group(containing: 5)?.activeWindow, 1)
        layout.remove(1)
        XCTAssertEqual(layout.group(containing: 5)?.activeWindow, 5)
        XCTAssertEqual(layout.shape, "row(D,col(5,2))")
    }

    func testTabbingAWindowFromAnotherGroupMovesIt() {
        var layout = Fixture.threeWay().layout
        layout.addTab(2, to: layout.group(containing: 1)!.id)
        XCTAssertEqual(layout.shape, "row(D,1+2)")
    }

    func testSuspendedWindowsKeepTheirSlotButTakeNoSpace() {
        var layout = Fixture.threeWay().layout
        layout.setSuspended(2, true)
        XCTAssertEqual(layout.shape, "row(D,col(1,2))")
        let rects = LayoutGeometry.rects(layout.root)
        let g1 = layout.group(containing: 1)!.id
        XCTAssertNil(rects[layout.group(containing: 2)!.id])
        XCTAssertEqual(rects[g1]!.height, 1, accuracy: 1e-9)
        layout.setSuspended(2, false)
        XCTAssertEqual(LayoutGeometry.rects(layout.root)[g1]!.height, 0.5, accuracy: 1e-9)
    }

    func testNormalizeRestoresMissingDesktopAndDropsDuplicates() {
        let root = LayoutNode.split(Split(axis: .horizontal, children: [
            .group(TabGroup(windows: [1, 2])),
            .group(TabGroup(windows: [2, 3])),
        ]))
        let layout = Layout(root: root)
        XCTAssertEqual(layout.shape, "row(1+2,3,D)")
    }

    func testExtraDesktopsAreRemoved() {
        let root = LayoutNode.split(Split(axis: .horizontal, children: [.desktop("a"), .group(TabGroup(windows: [1])), .desktop("b")]))
        let layout = Layout(root: root)
        XCTAssertEqual(layout.shape, "row(D,1)")
        XCTAssertEqual(layout.desktopID, "a")
    }

    func testRemap() {
        var layout = Fixture.threeWay().layout
        layout.remap([1: 101])
        XCTAssertEqual(layout.shape, "row(D,101)")
    }

    func testCodableRoundTrip() throws {
        var s = Fixture.threeWay()
        s.layout.addTab(7, to: s.layout.group(containing: 2)!.id)
        s.layout.setSuspended(7, true)
        s.floating[42] = Rect(x: 10, y: 20, width: 300, height: 200)
        s.windowInfo[1] = WindowInfo(bundleID: "com.apple.Safari", title: "Docs")
        s.saveView(3)
        let data = try WorkspaceSnapshot(displays: ["main": s]).encoded()
        let decoded = try WorkspaceSnapshot.decode(data)
        XCTAssertEqual(decoded.displays["main"], s)
    }

    func testDividedTilesExactly() {
        let r = Rect(x: 10, y: 0, width: 100, height: 50)
        let parts = r.divided(along: .horizontal, weights: [1, 2, 1])
        XCTAssertEqual(parts.map(\.width), [25, 50, 25])
        XCTAssertEqual(parts.last!.maxX, r.maxX)
    }
}

final class GeometryTests: XCTestCase {
    func testClampedInto() {
        let bounds = Rect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(Rect(x: 90, y: -10, width: 30, height: 30).clamped(into: bounds), Rect(x: 70, y: 0, width: 30, height: 30))
        XCTAssertEqual(Rect(x: 10, y: 10, width: 300, height: 50).clamped(into: bounds), Rect(x: 0, y: 10, width: 100, height: 50))
    }

    func testMappedBetweenRects() {
        let r = Rect(x: 10, y: 10, width: 20, height: 20)
        let mapped = r.mapped(from: Rect(x: 0, y: 0, width: 100, height: 100), to: Rect(x: 100, y: 0, width: 50, height: 200))
        XCTAssertEqual(mapped, Rect(x: 105, y: 20, width: 10, height: 40))
    }

    func testNearestEdgeIsRelativeToSize() {
        let wide = Rect(x: 0, y: 0, width: 1000, height: 100)
        XCTAssertEqual(wide.nearestEdge(to: Point(x: 50, y: 50)), .left)
        XCTAssertEqual(wide.nearestEdge(to: Point(x: 500, y: 5)), .top)
    }
}

final class SiblingRangeDockingTests: XCTestCase {
    /// row(D, 1, 2, 3)
    func makeRow() -> Layout {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .right)
        layout.dock(3, beside: .node(layout.group(containing: 2)!.id), edge: .right)
        return layout
    }

    func testDockingAlongTheRangeAxisInsertsBesideIt() {
        var layout = makeRow()
        let ids = [layout.group(containing: 1)!.id, layout.group(containing: 2)!.id]
        let before = LayoutGeometry.rects(layout.root)
        let rangeWidth = before[ids[0]]!.width + before[ids[1]]!.width
        layout.dock(9, beside: .siblings(split: layout.root.id, ids: ids), edge: .right, share: 0.5)
        XCTAssertEqual(layout.shape, "row(D,1,2,9,3)")
        let after = LayoutGeometry.rects(layout.root)
        // The range and the new window share the range's old width; everything else is untouched.
        XCTAssertEqual(after[layout.group(containing: 9)!.id]!.width, rangeWidth / 2, accuracy: 1e-9)
        XCTAssertEqual(after[layout.group(containing: 3)!.id]!.width, before[layout.group(containing: 3)!.id]!.width, accuracy: 1e-9)
    }

    func testDockingAcrossTheRangeAxisWrapsIt() {
        var layout = makeRow()
        let ids = [layout.group(containing: 1)!.id, layout.group(containing: 2)!.id]
        layout.dock(9, beside: .siblings(split: layout.root.id, ids: ids), edge: .top, share: 0.3)
        XCTAssertEqual(layout.shape, "row(D,col(9,row(1,2)),3)")
    }

    func testDockingBesideARangeContainingTheDraggedWindow() {
        var layout = makeRow()
        let ids = [layout.group(containing: 1)!.id, layout.group(containing: 2)!.id]
        layout.dock(1, beside: .siblings(split: layout.root.id, ids: ids), edge: .bottom, share: 0.5)
        XCTAssertEqual(Set(layout.allWindows), [1, 2, 3])
        XCTAssertEqual(layout.allWindows.count, 3)
    }
}
