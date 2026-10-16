import Foundation
import Testing
@testable import EspalierCore

struct NavigationTests {
    @Test func testOverviewResolvesToRoot() {
        let s = Fixture.threeWay()
        #expect(s.target == .node(s.layout.root.id))
    }

    @Test func testFramingFollowsWindowsNotNodes() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        #expect(s.target == .node(s.layout.group(containing: 2)!.id))
        // Restructure the layout: 2 is still framed.
        s.layout.dock(3, beside: .node(s.layout.desktopID), edge: .left)
        #expect(s.target == .node(s.layout.group(containing: 2)!.id))
    }

    @Test func testSiblingRangeResolution() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .right)
        layout.dock(3, beside: .node(layout.group(containing: 2)!.id), edge: .right)
        // row(D, 1, 2, 3): framing 1 and 2 is a sibling range.
        let target = layout.resolve(Framing(windows: [1, 2]))
        guard case .siblings(let split, let ids) = target else { Issue.record("\(target)"); return }
        #expect(split == layout.root.id)
        #expect(ids == [layout.group(containing: 1)!.id, layout.group(containing: 2)!.id])
        // Framing 1 and 3 includes 2 as well, since ranges are contiguous.
        guard case .siblings(_, let ids13) = layout.resolve(Framing(windows: [1, 3])) else { Issue.record(); return }
        #expect(ids13.count == 3)
        // Everything resolves to the root node.
        #expect(layout.resolve(Framing(windows: [1, 2, 3], desktop: true)) == .node(layout.root.id))
    }

    @Test func testZoomOutStepsThroughLevels() {
        var s = Fixture.threeWay()
        let g2 = s.layout.group(containing: 2)!.id
        s.frame(g2)
        s.zoomOut()
        guard case .node(let colID) = s.target, case .split(let col)? = s.layout.root.find(colID) else { Issue.record(); return }
        #expect(col.axis == .vertical)
        s.zoomOut()
        #expect(s.target == .node(s.layout.root.id))
        s.zoomOut()
        #expect(s.target == .node(s.layout.root.id))
    }

    @Test func testZoomOutFromSiblingRangeGoesToTheSplit() {
        var layout = Layout()
        layout.dock(1, beside: .node(layout.desktopID), edge: .right)
        layout.dock(2, beside: .node(layout.group(containing: 1)!.id), edge: .right)
        var s = DisplayState(layout: layout)
        s.navigation.go(to: Framing(windows: [1, 2]))
        s.zoomOut()
        #expect(s.target == .node(s.layout.root.id))
    }

    @Test func testZoomInTowardAPoint() {
        var s = Fixture.threeWay()
        // Right half of the screen, bottom quarter: window 2.
        s.zoomIn(toward: Point(x: 1400, y: 900), screen: Fixture.screen, metrics: Fixture.metrics)
        guard case .node(let id) = s.target, case .split? = s.layout.root.find(id) else { Issue.record(); return }
        s.zoomIn(toward: Point(x: 800, y: 900), screen: Fixture.screen, metrics: Fixture.metrics)
        #expect(s.target == .node(s.layout.group(containing: 2)!.id))
        // A single window can't be zoomed into further.
        s.zoomIn(toward: nil, screen: Fixture.screen, metrics: Fixture.metrics)
        #expect(s.target == .node(s.layout.group(containing: 2)!.id))
    }

    @Test func testBackAndForward() {
        var s = Fixture.threeWay()
        let root = s.target
        s.frame(s.layout.group(containing: 1)!.id)
        let one = s.target
        s.frame(s.layout.group(containing: 2)!.id)
        s.back()
        #expect(s.target == one)
        s.back()
        #expect(s.target == root)
        s.back()
        #expect(s.target == root)
        s.forward()
        #expect(s.target == one)
    }

    @Test func testOverviewToggleReturns() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        let one = s.target
        s.toggleOverview()
        #expect(s.target == .node(s.layout.root.id))
        s.toggleOverview()
        #expect(s.target == one)
    }

    @Test func testMaximizeToggleRestoresPreviousFraming() {
        var s = Fixture.threeWay()
        let colTarget = s.layout.parentTarget(of: .node(s.layout.group(containing: 1)!.id))!
        s.frame(colTarget)
        s.toggleMaximize(2)
        #expect(s.target == .node(s.layout.group(containing: 2)!.id))
        s.toggleMaximize(2)
        #expect(s.target == colTarget)
    }

    @Test func testSavedViews() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        s.saveView(1)
        s.toggleOverview()
        s.recallView(1)
        #expect(s.target == .node(s.layout.group(containing: 1)!.id))
        s.recallView(2) // empty slot: nothing happens
        #expect(s.target == .node(s.layout.group(containing: 1)!.id))
        s.saveView(0) // out of range
        #expect(s.navigation.saved["0"] == nil)
    }

    @Test func testRevealWidensToIncludeAWindow() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        s.reveal(2, screen: nil, metrics: nil)
        guard case .node(let id) = s.target, case .split(let col)? = s.layout.root.find(id) else { Issue.record(); return }
        #expect(col.axis == .vertical)
    }

    @Test func testRevealZoomsInUntilTheWindowIsUsable() {
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
        #expect(s.presentation(screen: screen, metrics: metrics).windowFrames[6] == nil)
        s.reveal(6, screen: screen, metrics: metrics)
        #expect(s.presentation(screen: screen, metrics: metrics).windowFrames[6] != nil)
        #expect(s.target != .node(s.layout.root.id))
    }

    @Test func testRevealingAFloatingWindowShowsTheDesktop() {
        var s = Fixture.threeWay()
        s.floating[9] = Rect(x: 0, y: 0, width: 100, height: 100)
        s.frame(s.layout.group(containing: 1)!.id)
        s.reveal(9, screen: nil, metrics: nil)
        #expect(s.target == .node(s.layout.root.id))
    }

    @Test func testForgettingAWindowPrunesFramings() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        s.saveView(4)
        s.forget(2)
        #expect(s.navigation.saved["4"] == nil)
        #expect(s.target == .node(s.layout.root.id))
    }

    @Test func testCameraInterpolationEndpoints() {
        let a = Rect.unit
        let b = Rect(x: 0.5, y: 0.5, width: 0.25, height: 0.5)
        #expect(Camera.interpolate(from: a, to: b, t: 0).isApproximatelyEqual(to: a, tolerance: 1e-9))
        #expect(Camera.interpolate(from: a, to: b, t: 1).isApproximatelyEqual(to: b, tolerance: 1e-9))
        #expect(abs(Camera.interpolate(from: a, to: b, t: 0.5).width - 0.5) <= 1e-9)
    }

    @Test func testMapAndUnmapAreInverse() {
        let world = Rect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let screen = Fixture.screen
        let p = Point(x: 0.75, y: 0.3)
        let mapped = Camera.map(Rect(origin: p, size: .zero), world: world, onto: screen).origin
        let back = Camera.unmap(mapped, world: world, from: screen)
        #expect(abs(back.x - p.x) <= 1e-9)
        #expect(abs(back.y - p.y) <= 1e-9)
    }
}
