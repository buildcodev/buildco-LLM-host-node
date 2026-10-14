import XCTest
@testable import EspalierCore

final class InteractionTests: XCTestCase {
    let screen = Fixture.screen
    let metrics = Fixture.metrics

    // Layout: desktop on the left half; window 1 top right, window 2 bottom right.

    func testDropOnScreenEdgeDocksBesideEverything() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 5, y: 500), presentation: p, metrics: metrics), .dock(.node(s.layout.root.id), .left))
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 1000, y: 1020), presentation: p, metrics: metrics), .dock(.node(s.layout.root.id), .bottom))
        // Up in the menu bar counts as the top edge.
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 1000, y: 10), presentation: p, metrics: metrics), .dock(.node(s.layout.root.id), .top))
    }

    func testDropOnWindowEdgeDocksBesideIt() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        let g1 = s.layout.group(containing: 1)!.id
        // Window 1 spans x 800–1600, y 25–525. Its left band is 14% of 500 = 70 px.
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 830, y: 300), presentation: p, metrics: metrics), .dock(.node(g1), .left))
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 1200, y: 500), presentation: p, metrics: metrics), .dock(.node(g1), .bottom))
    }

    func testDropOnTitleBarAddsATab() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 1200, y: 40), presentation: p, metrics: metrics), .tab(s.layout.group(containing: 1)!.id))
    }

    func testDropInMiddleOfAWindow() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        // A floating window stays floating; a docked one snaps back.
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 1200, y: 300), presentation: p, metrics: metrics), .float)
        XCTAssertEqual(s.dropAction(for: 2, at: Point(x: 1200, y: 300), presentation: p, metrics: metrics), .none)
    }

    func testDropOnDesktop() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(s.dropAction(for: 1, at: Point(x: 400, y: 500), presentation: p, metrics: metrics), .float)
        XCTAssertEqual(s.dropAction(for: 9, at: Point(x: 770, y: 500), presentation: p, metrics: metrics), .dock(.node(s.layout.desktopID), .right))
    }

    func testDroppingOnOwnSlotDoesNothing() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(s.dropAction(for: 1, at: Point(x: 830, y: 300), presentation: p, metrics: metrics), .none)
    }

    func testDropInAGapInsertsBetween() {
        var m = LayoutMetrics()
        m.gap = 20
        m.margin = 0
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: m)
        let action = s.dropAction(for: 9, at: Point(x: 1200, y: 525), presentation: p, metrics: m)
        XCTAssertEqual(action, .dock(.node(s.layout.group(containing: 1)!.id), .bottom))
    }

    func testApplyDockAndPreview() {
        var s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        let action = s.dropAction(for: 9, at: Point(x: 830, y: 300), presentation: p, metrics: metrics)
        let preview = s.previewFrame(for: action, window: 9, frame: Rect(x: 0, y: 0, width: 500, height: 400), screen: screen, metrics: metrics)
        XCTAssertEqual(preview, Rect(x: 800, y: 25, width: 400, height: 500))
        s.applyDrop(action, window: 9, frame: .zero, screen: screen, metrics: metrics)
        XCTAssertEqual(s.layout.shape, "row(D,col(row(9,1),2))")
        XCTAssertEqual(s.presentation(screen: screen, metrics: metrics).windowFrames[9], preview)
    }

    func testDockingBesideTheDesktopKeepsTheWindowsSize() {
        var s = DisplayState()
        s.adoptFloating(9, frame: Rect(x: 100, y: 100, width: 400, height: 600), info: nil)
        s.applyDrop(.dock(.node(s.layout.desktopID), .left), window: 9, frame: Rect(x: 100, y: 100, width: 400, height: 600), screen: screen, metrics: metrics)
        XCTAssertFalse(s.isFloating(9))
        XCTAssertEqual(s.presentation(screen: screen, metrics: metrics).windowFrames[9]?.width ?? 0, 400, accuracy: 1e-6)
    }

    func testDockingAtTheScreenEdgeWhileZoomedWidensTheFraming() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        let p = s.presentation(screen: screen, metrics: metrics)
        let action = s.dropAction(for: 9, at: Point(x: 5, y: 500), presentation: p, metrics: metrics)
        XCTAssertEqual(action, .dock(.node(s.layout.group(containing: 2)!.id), .left))
        s.applyDrop(action, window: 9, frame: Rect(x: 0, y: 0, width: 300, height: 300), screen: screen, metrics: metrics)
        let after = s.presentation(screen: screen, metrics: metrics)
        XCTAssertNotNil(after.windowFrames[9])
        XCTAssertNotNil(after.windowFrames[2])
        XCTAssertNil(after.windowFrames[1])
    }

    func testFloatingADockedWindow() {
        var s = Fixture.threeWay()
        s.applyDrop(.float, window: 2, frame: Rect(x: 50, y: 60, width: 300, height: 200), screen: screen, metrics: metrics)
        XCTAssertEqual(s.layout.shape, "row(D,1)")
        XCTAssertEqual(s.floating[2], Rect(x: 50, y: 60, width: 300, height: 200))
    }

    func testToggleFloat() {
        var s = DisplayState()
        s.adoptFloating(5, frame: Rect(x: 0, y: 0, width: 600, height: 400), info: nil)
        s.toggleFloat(5, currentFrame: Rect(x: 0, y: 0, width: 600, height: 400), screen: screen, metrics: metrics)
        XCTAssertEqual(s.layout.shape, "row(D,5)")
        s.toggleFloat(5, currentFrame: Rect(x: 1000, y: 25, width: 600, height: 1000), screen: screen, metrics: metrics)
        XCTAssertEqual(s.layout.shape, "D")
        XCTAssertTrue(s.isFloating(5))
    }

    func testArrangeDocksEveryFloatingWindow() {
        var s = DisplayState()
        for w: WindowID in 1...4 {
            s.adoptFloating(w, frame: Rect(x: 0, y: 0, width: Double(100 * w), height: 100), info: nil)
        }
        s.arrange(screen: screen, metrics: metrics)
        XCTAssertTrue(s.floating.isEmpty)
        XCTAssertEqual(Set(s.layout.allWindows), [1, 2, 3, 4])
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(Set(p.windowFrames.keys), [1, 2, 3, 4])
        // No two windows overlap.
        let frames = Array(p.windowFrames.values)
        for i in frames.indices { for j in frames.indices where i < j { XCTAssertFalse(frames[i].overlaps(frames[j])) } }
    }

    func testMovingADivider() {
        var s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        let divider = p.dividers.first { $0.axis == .horizontal }!
        s.moveDivider(divider, to: 600, metrics: metrics)
        let after = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(after.desktopRect!.width, 600, accuracy: 1e-6)
        XCTAssertEqual(after.windowFrames[1]!.minX, 600, accuracy: 1e-6)
        // Clamped to the minimum span. At 120 px the desktop is too small to use, so it's a tile.
        s.moveDivider(divider, to: 10, metrics: metrics)
        let clamped = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(clamped.nodeRects[s.layout.desktopID]!.width, metrics.minimumSpan, accuracy: 1e-6)
        XCTAssertNil(clamped.desktopRect)
        XCTAssertEqual(clamped.tiles.map(\.kind), [.desktop])
    }

    func testResizingADockedWindowMovesItsDividers() {
        var s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        let old = p.windowFrames[2]!
        var new = old
        new.y -= 100
        new.height += 100
        new.x += 50
        new.width -= 50
        s.resizeDocked(2, from: old, to: new, presentation: p, metrics: metrics)
        let after = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(after.windowFrames[2]!.minY, new.minY, accuracy: 1e-6)
        XCTAssertEqual(after.windowFrames[1]!.maxY, new.minY, accuracy: 1e-6)
        XCTAssertEqual(after.windowFrames[2]!.minX, new.minX, accuracy: 1e-6)
        XCTAssertEqual(after.desktopRect!.maxX, new.minX, accuracy: 1e-6)
    }

    func testDirectionalNeighbours() {
        let s = Fixture.threeWay()
        var p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(s.neighbour(of: 1, toward: .bottom, presentation: p), 2)
        XCTAssertEqual(s.neighbour(of: 2, toward: .top, presentation: p), 1)
        XCTAssertNil(s.neighbour(of: 1, toward: .right, presentation: p))
        p.windowFrames[7] = Rect(x: 0, y: 25, width: 800, height: 1000)
        XCTAssertEqual(s.neighbour(of: 2, toward: .left, presentation: p), 7)
    }

    func testAdoptingAWindowWhileZoomedWidensToTheDesktop() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        s.adoptFloating(8, frame: Rect(x: 0, y: 0, width: 100, height: 100), info: WindowInfo(bundleID: "x", title: "y"))
        XCTAssertEqual(s.target, .node(s.layout.root.id))
        XCTAssertEqual(s.windowInfo[8]?.bundleID, "x")
    }
}

final class ArrangeFilterTests: XCTestCase {
    func testArrangeOnlyDocksTheChosenWindows() {
        var s = DisplayState()
        s.adoptFloating(1, frame: Rect(x: 0, y: 0, width: 100, height: 100), info: nil)
        s.adoptFloating(2, frame: Rect(x: 0, y: 0, width: 100, height: 100), info: nil)
        s.arrange(screen: Fixture.screen, metrics: Fixture.metrics, only: [2])
        XCTAssertTrue(s.isFloating(1))
        XCTAssertTrue(s.isDocked(2))
    }
}
