import Foundation
import Testing
@testable import EspalierCore

struct PresentationTests {
    let screen = Fixture.screen

    @Test func testOverviewPlacesEveryWindow() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(p.windowFrames[1] == Rect(x: 800, y: 25, width: 800, height: 500))
        #expect(p.windowFrames[2] == Rect(x: 800, y: 525, width: 800, height: 500))
        #expect(p.desktopRect == Rect(x: 0, y: 25, width: 800, height: 1000))
        #expect(p.parked.isEmpty)
        #expect(p.tiles.isEmpty)
    }

    @Test func testGapsAndMargins() {
        var metrics = LayoutMetrics()
        metrics.gap = 10
        metrics.margin = 20
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        let w1 = p.windowFrames[1]!, w2 = p.windowFrames[2]!, d = p.desktopRect!
        #expect(abs(d.minX - (screen.minX + 20)) <= 1e-9)
        #expect(abs(w1.maxX - (screen.maxX - 20)) <= 1e-9)
        #expect(abs(w1.minY - (screen.minY + 20)) <= 1e-9)
        #expect(abs((w2.minY - w1.maxY) - 10) <= 1e-9)
        #expect(abs((w1.minX - d.maxX) - 10) <= 1e-9)
    }

    @Test func testFramingOneWindowParksTheRest() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 2)!.id)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(p.windowFrames[2] == screen)
        #expect(p.windowFrames[1] == nil)
        #expect(p.parked == [1])
        #expect(p.desktopRect == nil)
        #expect(p.tiles.isEmpty, "off-screen nodes get no tiles")
    }

    @Test func testTooSmallWindowsBecomeTiles() {
        var metrics = Fixture.metrics
        metrics.usableSize = Size(width: 900, height: 400)
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: metrics)
        #expect(p.windowFrames.isEmpty)
        #expect(Set(p.parked) == [1, 2])
        #expect(p.tiles.map(\.kind) == [.desktop, .window(1), .window(2)])
    }

    @Test func testLearnedMinimumSizesMakeTiles() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: Fixture.metrics, minSizes: [2: Size(width: 1000, height: 300)])
        #expect(p.windowFrames[1] != nil)
        #expect(p.windowFrames[2] == nil)
        #expect(p.tiles.first?.kind == .window(2))
    }

    @Test func testDeeplyNestedGroupsCollapseIntoOneTile() {
        var s = DisplayState()
        s.layout.dock(1, beside: .node(s.layout.desktopID), edge: .right, share: 0.9)
        // A small nested group in the corner of window 1's area.
        s.layout.dock(2, beside: .node(s.layout.group(containing: 1)!.id), edge: .bottom, share: 0.04)
        s.layout.dock(3, beside: .node(s.layout.group(containing: 2)!.id), edge: .right, share: 0.5)
        s.layout.dock(4, beside: .node(s.layout.group(containing: 3)!.id), edge: .bottom, share: 0.5)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        let groupTiles = p.tiles.filter { $0.kind == .group }
        #expect(groupTiles.count == 1)
        #expect(Set(groupTiles[0].windows) == [2, 3, 4])
        #expect(!groupTiles[0].lines.isEmpty)
        #expect(!(p.tiles.contains { $0.kind == .window(3) }))
        // Zooming to the group shows it in full.
        s.frame(groupTiles[0].node)
        let zoomed = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(zoomed.tiles.isEmpty)
        #expect(Set(zoomed.windowFrames.keys) == [2, 3, 4])
    }

    @Test func testFlatRowsOfSmallWindowsKeepTheirTiles() {
        var s = DisplayState()
        s.layout.dock(1, beside: .node(s.layout.desktopID), edge: .bottom, share: 0.03)
        s.layout.dock(2, beside: .node(s.layout.group(containing: 1)!.id), edge: .right)
        s.layout.dock(3, beside: .node(s.layout.group(containing: 2)!.id), edge: .right)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(p.tiles.filter { if case .window = $0.kind { return true } else { return false } }.count == 3)
    }

    @Test func testTabStripReservesSpace() {
        var s = Fixture.threeWay()
        s.layout.addTab(5, to: s.layout.group(containing: 1)!.id)
        var metrics = Fixture.metrics
        metrics.tabBarHeight = 30
        let p = s.presentation(screen: screen, metrics: metrics)
        #expect(p.tabStrips.count == 1)
        #expect(p.tabStrips[0].tabs == [1, 5])
        #expect(p.tabStrips[0].active == 5)
        #expect(p.windowFrames[5] == Rect(x: 800, y: 55, width: 800, height: 470))
        #expect(p.parked.contains(1))
        #expect(p.tabStrips[0].tab(at: Point(x: 810, y: 30)) == 1)
        #expect(p.tabStrips[0].tab(at: Point(x: 1590, y: 30)) == 5)
    }

    @Test func testSuspendedWindowsAreNeitherPlacedNorParked() {
        var s = Fixture.threeWay()
        s.layout.setSuspended(2, true)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(p.windowFrames[2] == nil)
        #expect(!p.parked.contains(2))
        #expect(p.windowFrames[1]?.height == 1000)
    }

    @Test func testDividers() {
        let s = Fixture.threeWay()
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(p.dividers.count == 2)
        let vertical = p.dividers.first { $0.axis == .horizontal }!
        #expect(vertical.position == 800)
        #expect(vertical.hitRect.contains(Point(x: 801, y: 500)))
        #expect(p.divider(at: Point(x: 1200, y: 525)) != nil)
    }

    @Test func testDividersOnlyBetweenVisibleNeighbours() {
        var s = Fixture.threeWay()
        s.frame(s.layout.group(containing: 1)!.id)
        let p = s.presentation(screen: screen, metrics: Fixture.metrics)
        #expect(p.dividers.isEmpty)
    }

    @Test func testCameraOverrideForAnimation() {
        let s = Fixture.threeWay()
        let p = s.layout.presentation(target: s.target, screen: screen, metrics: Fixture.metrics, camera: Rect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(p.windowFrames[1] == Rect(x: 0, y: 25, width: 1600, height: 500))
    }
}
