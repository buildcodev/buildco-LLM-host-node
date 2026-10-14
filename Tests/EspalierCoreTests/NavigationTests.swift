import XCTest
@testable import EspalierCore

final class NavigationTests: XCTestCase {
    func testOverviewResolvesToRoot() {
        let s = Fixture.threeWay()
        XCTAssertEqual(s.target, .node(s.layout.root.id))
    }

    func testFramingFollowsWindowsNotNodes() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 2)!.id))
        // Restructure the layout: 2 is still framed.
        s.layout.dock(3, beside: .node(s.layout.desktopID), edge: .left)
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 2)!.id))
    }

    func testSiblingRangeResolution() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .right)
        layout.dock(3, beside: .node(layout.group(containing: 2)!.id), edge: .right)
        // row(D, 1, 2, 3): framing 1 and 2 is a sibling range.
        let target = layout.resolve(Framing(windows: [1, 2]))
        guard case .siblings(let split, let ids) = target else { return XCTFail("\(target)") }
        XCTAssertEqual(split, layout.root.id)
        XCTAssertEqual(ids, [layout.group(containing: 1)!.id, layout.group(containing: 2)!.id])
        // Framing 1 and 3 includes 2 as well, since ranges are contiguous.
        guard case .siblings(_, let ids13) = layout.resolve(Framing(windows: [1, 3])) else { return XCTFail() }
        XCTAssertEqual(ids13.count, 3)
        // Everything resolves to the root node.
        XCTAssertEqual(layout.resolve(Framing(windows: [1, 2, 3], desktop: true)), .node(layout.root.id))
    }

    func testZoomOutStepsThroughLevels() {
        var s = Fixture.threeWay()
        let g2 = s.layout.group(containing: 2)!.id
        s.frame(g2)
        s.zoomOut()
        guard case .node(let colID) = s.target, case .split(let col)? = s.layout.root.find(colID) else { return XCTFail() }
        XCTAssertEqual(col.axis, .vertical)
        s.zoomOut()
        XCTAssertEqual(s.target, .node(s.layout.root.id))
        s.zoomOut()
        XCTAssertEqual(s.target, .node(s.layout.root.id))
    }

    func testZoomOutFromSiblingRangeGoesToTheSplit() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .right)
        var s = DisplayState(layout: layout)
        s.navigation.go(to: Framing(windows: [1, 2]))
        s.zoomOut()
        XCTAssertEqual(s.target, .node(s.layout.root.id))
    }

    func testZoomInTowardAPoint() {
        var s = Fixture.threeWay()
        // Right half of the screen, bottom quarter: window 2.
        s.zoomIn(toward: Point(x: 1400, y: 900), screen: Fixture.screen, metrics: Fixture.metrics)
        guard case .node(let id) = s.target, case .split? = s.layout.root.find(id) else { return XCTFail() }
        s.zoomIn(toward: Point(x: 800, y: 900), screen: Fixture.screen, metrics: Fixture.metrics)
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 2)!.id))
        // A single window can't be zoomed into further.
        s.zoomIn(toward: nil, screen: Fixture.screen, metrics: Fixture.metrics)
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 2)!.id))
    }

    func testBackAndForward() {
        var s = Fixture.threeWay()
        let root = s.target
        s.frame(s.layout.group(containing: 1)!.id)
        let one = s.target
        s.frame(s.layout.group(containing: 2)!.id)
        s.back()
        XCTAssertEqual(s.target, one)
        s.back()
        XCTAssertEqual(s.target, root)
        s.back()
        XCTAssertEqual(s.target, root)
        s.forward()
        XCTAssertEqual(s.target, one)
    }

    func testOverviewToggleReturns() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        let one = s.target
        s.toggleOverview()
        XCTAssertEqual(s.target, .node(s.layout.root.id))
        s.toggleOverview()
        XCTAssertEqual(s.target, one)
    }

    func testMaximizeToggleRestoresPreviousFraming() {
        var s = Fixture.threeWay()
        let colTarget = s.layout.parentTarget(of: .node(s.layout.group(containing: 1)!.id))!
        s.frame(colTarget)
        s.toggleMaximize(2)
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 2)!.id))
        s.toggleMaximize(2)
        XCTAssertEqual(s.target, colTarget)
    }

    func testSavedViews() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        s.saveView(1)
        s.toggleOverview()
        s.recallView(1)
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 1)!.id))
        s.recallView(2) // empty slot: nothing happens
        XCTAssertEqual(s.target, .node(s.layout.group(containing: 1)!.id))
        s.saveView(0) // out of range
        XCTAssertNil(s.navigation.saved["0"])
    }

    func testRevealWidensToIncludeAWindow() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        s.reveal(2, screen: nil, metrics: nil)
        guard case .node(let id) = s.target, case .split(let col)? = s.layout.root.find(id) else { return XCTFail() }
        XCTAssertEqual(col.axis, .vertical)
    }

    func testRevealZoomsInUntilTheWindowIsUsable() {
        // Nest deeply so window 6 is tiny in the overview.
        var s = DisplayState()
        s.layout.dock(1, beside: .node(s.layout.desktopID), edge: .right, share: 0.5)
        var last: WindowID = 1
        for w: WindowID in 2...6 {
            s.layout.dock(w, beside: .node(s.layout.group(containing: last)!.id), edge: w % 2 == 0 ? .bottom : .right)
            last = w
        }
        let screen = Fixture.screen
        var metrics = LayoutMetrics()
        metrics.usableSize = Size(width: 200, height: 120)
        XCTAssertNil(s.presentation(screen: screen, metrics: metrics).windowFrames[6])
        s.reveal(6, screen: screen, metrics: metrics)
        XCTAssertNotNil(s.presentation(screen: screen, metrics: metrics).windowFrames[6])
        XCTAssertNotEqual(s.target, .node(s.layout.root.id))
    }

    func testRevealingAFloatingWindowShowsTheDesktop() {
        var s = Fixture.threeWay()
        s.floating[9] = Rect(x: 0, y: 0, width: 100, height: 100)
        s.frame(s.layout.group(containing: 1)!.id)
        s.reveal(9, screen: nil, metrics: nil)
        XCTAssertEqual(s.target, .node(s.layout.root.id))
    }

    func testForgettingAWindowPrunesFramings() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        s.saveView(4)
        s.forget(2)
        XCTAssertNil(s.navigation.saved["4"])
        XCTAssertEqual(s.target, .node(s.layout.root.id))
    }

    func testCameraInterpolationEndpoints() {
        let a = Rect.unit
        let b = Rect(x: 0.5, y: 0.5, width: 0.25, height: 0.5)
        XCTAssertTrue(Camera.interpolate(from: a, to: b, t: 0).isApproximatelyEqual(to: a, tolerance: 1e-9))
        XCTAssertTrue(Camera.interpolate(from: a, to: b, t: 1).isApproximatelyEqual(to: b, tolerance: 1e-9))
        XCTAssertEqual(Camera.interpolate(from: a, to: b, t: 0.5).width, 0.5, accuracy: 1e-9)
    }

    func testMapAndUnmapAreInverse() {
        let world = Rect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let screen = Fixture.screen
        let p = Point(x: 0.75, y: 0.3)
        let mapped = Camera.map(Rect(origin: p, size: .zero), world: world, onto: screen).origin
        let back = Camera.unmap(mapped, world: world, from: screen)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }
}
