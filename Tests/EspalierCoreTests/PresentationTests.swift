import XCTest
@testable import EspalierCore

final class PresentationTests: XCTestCase {
    let screen = Fixture.screen

    func testOverviewPlacesEveryWindow() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertEqual(p.windowFrames[1], Rect(x: 800, y: 25, width: 800, height: 500))
        XCTAssertEqual(p.windowFrames[2], Rect(x: 800, y: 525, width: 800, height: 500))
        XCTAssertEqual(p.desktopRect, Rect(x: 0, y: 25, width: 800, height: 1000))
        XCTAssertTrue(p.parked.isEmpty)
        XCTAssertTrue(p.tiles.isEmpty)
    }

    func testGapsAndMargins() {
        var metrics = LayoutMetrics()
        metrics.gap = 10
        metrics.margin = 20
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        let w1 = p.windowFrames[1]!, w2 = p.windowFrames[2]!, d = p.desktopRect!
        XCTAssertEqual(d.minX, screen.minX + 20, accuracy: 1e-9)
        XCTAssertEqual(w1.maxX, screen.maxX - 20, accuracy: 1e-9)
        XCTAssertEqual(w1.minY, screen.minY + 20, accuracy: 1e-9)
        XCTAssertEqual(w2.minY - w1.maxY, 10, accuracy: 1e-9)
        XCTAssertEqual(w1.minX - d.maxX, 10, accuracy: 1e-9)
    }

    func testFramingOneWindowParksTheRest() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertEqual(p.windowFrames[2], screen)
        XCTAssertNil(p.windowFrames[1])
        XCTAssertEqual(p.parked, [1])
        XCTAssertNil(p.desktopRect)
        XCTAssertTrue(p.tiles.isEmpty, "off-screen nodes get no tiles")
    }

    func testTooSmallWindowsBecomeTiles() {
        var metrics = Fixture.metrics
        metrics.usableSize = Size(width: 900, height: 400)
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertTrue(p.windowFrames.isEmpty)
        XCTAssertEqual(Set(p.parked), [1, 2])
        XCTAssertEqual(p.tiles.map(\.kind), [.desktop, .window(1), .window(2)])
    }

    func testLearnedMinimumSizesMakeTiles() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: Fixture.metrics, minSizes: [2: Size(width: 1000, height: 300)])
        XCTAssertNotNil(p.windowFrames[1])
        XCTAssertNil(p.windowFrames[2])
        XCTAssertEqual(p.tiles.first?.kind, .window(2))
    }

    func testDeeplyNestedGroupsCollapseIntoOneTile() {
        var s = DisplayState()
        s.layout.dock(1, beside: .node(s.layout.desktopID), edge: .right, share: 0.9)
        // A small nested group in the corner of window 1's area.
        s.layout.dock(2, beside: .node(s.layout.group(containing: 1)!.id), edge: .bottom, share: 0.04)
        s.layout.dock(3, beside: .node(s.layout.group(containing: 2)!.id), edge: .right, share: 0.5)
        s.layout.dock(4, beside: .node(s.layout.group(containing: 3)!.id), edge: .bottom, share: 0.5)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        let groupTiles = p.tiles.filter { $0.kind == .group }
        XCTAssertEqual(groupTiles.count, 1)
        XCTAssertEqual(Set(groupTiles[0].windows), [2, 3, 4])
        XCTAssertFalse(groupTiles[0].lines.isEmpty)
        XCTAssertFalse(p.tiles.contains { $0.kind == .window(3) })
        // Zooming to the group shows it in full.
        s.frame(groupTiles[0].node)
        let zoomed = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertTrue(zoomed.tiles.isEmpty)
        XCTAssertEqual(Set(zoomed.windowFrames.keys), [2, 3, 4])
    }

    func testFlatRowsOfSmallWindowsKeepTheirTiles() {
        var s = DisplayState()
        s.layout.dock(1, beside: .node(s.layout.desktopID), edge: .bottom, share: 0.03)
        s.layout.dock(2, beside: .node(s.layout.group(containing: 1)!.id), edge: .right)
        s.layout.dock(3, beside: .node(s.layout.group(containing: 2)!.id), edge: .right)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertEqual(p.tiles.filter { if case .window = $0.kind { return true } else { return false } }.count, 3)
    }

    func testTabStripReservesSpace() {
        var s = Fixture.threeWay()
        s.layout.addTab(5, to: s.layout.group(containing: 1)!.id)
        var metrics = Fixture.metrics
        metrics.tabBarHeight = 30
        let p = s.presentation(screen: screen, metrics: metrics)
        XCTAssertEqual(p.tabStrips.count, 1)
        XCTAssertEqual(p.tabStrips[0].tabs, [1, 5])
        XCTAssertEqual(p.tabStrips[0].active, 5)
        XCTAssertEqual(p.windowFrames[5], Rect(x: 800, y: 55, width: 800, height: 470))
        XCTAssertTrue(p.parked.contains(1))
        XCTAssertEqual(p.tabStrips[0].tab(at: Point(x: 810, y: 30)), 1)
        XCTAssertEqual(p.tabStrips[0].tab(at: Point(x: 1590, y: 30)), 5)
    }

    func testSuspendedWindowsAreNeitherPlacedNorParked() {
        var s = Fixture.threeWay()
        s.layout.setSuspended(2, true)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertNil(p.windowFrames[2])
        XCTAssertFalse(p.parked.contains(2))
        XCTAssertEqual(p.windowFrames[1]?.height, 1000)
    }

    func testDividers() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertEqual(p.dividers.count, 2)
        let vertical = p.dividers.first { $0.axis == .horizontal }!
        XCTAssertEqual(vertical.position, 800)
        XCTAssertTrue(vertical.hitRect.contains(Point(x: 801, y: 500)))
        XCTAssertNotNil(p.divider(at: Point(x: 1200, y: 525)))
    }

    func testDividersOnlyBetweenVisibleNeighbours() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        XCTAssertTrue(p.dividers.isEmpty)
    }

    func testCameraOverrideForAnimation() {
        let s = Fixture.threeWay()
        let p = s.layout.presentation(target: s.target, screen: screen, metrics: Fixture.metrics, camera: Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(p.windowFrames[1], Rect(x: 0, y: 25, width: 1600, height: 500))
    }
}
