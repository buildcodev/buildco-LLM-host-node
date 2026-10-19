import Foundation
import Testing
@testable import EspalierCore

struct TabsTests {
    let frame = Rect(x: 0, y: 60, width: 1312, height: 1342)

    @Test func testDroppingOnALoneWindowMakesAGroup() {
        var tabs = TabGroups()
        let hidden = tabs.add(2, to: 1, frame: frame)
        #expect(hidden == 1)
        #expect(tabs.groups == [TabGroup(windows: [1, 2], active: 2, frame: frame)])
        #expect(tabs.isHidden(1) && !tabs.isHidden(2) && !tabs.isHidden(3))
    }

    @Test func testDroppingOnAGroupInsertsAfterTheTarget() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(3, to: 1, frame: .zero)
        let g = tabs.group(containing: 3)!
        #expect(g.windows == [1, 3, 2])
        #expect(g.active == 3)
        #expect(g.frame == frame, "the group keeps its frame")
        tabs.add(4, to: 2, frame: .zero, at: 0)
        #expect(tabs.group(containing: 4)!.windows == [4, 1, 3, 2])
    }

    @Test func testMovingAWindowBetweenGroups() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(4, to: 3, frame: frame)
        tabs.add(5, to: 3, frame: frame)
        // 2 leaves 1's group, which dissolves, and joins 3's.
        tabs.add(2, to: 3, frame: .zero)
        #expect(tabs.group(containing: 1) == nil)
        #expect(tabs.group(containing: 2)!.windows == [3, 2, 5, 4])
        #expect(tabs.groups.count == 1)
    }

    @Test func testReorderingWithinAGroup() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(3, to: 2, frame: frame)
        tabs.add(1, to: 3, frame: frame)
        #expect(tabs.group(containing: 1)!.windows == [2, 3, 1])
        #expect(tabs.group(containing: 1)!.active == 1)
        tabs.move(1, to: 0)
        #expect(tabs.group(containing: 1)!.windows == [1, 2, 3])
    }

    @Test func testRemovingTheShownTabShowsItsRightNeighbour() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(3, to: 2, frame: frame)
        tabs.activate(2)
        let removal = tabs.remove(2)
        #expect(removal == TabGroups.Removal(shown: 3, dissolved: nil, frame: frame))
        #expect(tabs.group(containing: 1)!.windows == [1, 3])
        // The last tab falls back to its left neighbour.
        tabs.activate(3)
        #expect(tabs.remove(3) == TabGroups.Removal(shown: 1, dissolved: 1, frame: frame))
        #expect(tabs.groups.isEmpty)
    }

    @Test func testRemovingAHiddenTabKeepsTheShownOne() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(3, to: 2, frame: frame)
        #expect(tabs.remove(1) == TabGroups.Removal(shown: nil, dissolved: nil, frame: frame))
        #expect(tabs.group(containing: 3)!.active == 3)
        #expect(tabs.remove(9) == nil)
    }

    @Test func testNeighboursWrapAround() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(3, to: 2, frame: frame)
        #expect(tabs.neighbour(of: 3, forward: true) == 1)
        #expect(tabs.neighbour(of: 1, forward: false) == 3)
        #expect(tabs.neighbour(of: 2, forward: true) == 3)
        #expect(tabs.neighbour(of: 7, forward: true) == nil)
    }

    @Test func testActivateReportsTheTabItHid() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        #expect(tabs.activate(1) == 2)
        #expect(tabs.activate(1) == nil)
    }

    @Test func testRemapAfterRestart() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.add(3, to: 2, frame: frame)
        tabs.add(5, to: 4, frame: frame)
        // 1 and 2 were found again under new ids; 3 and 5 are gone.
        tabs.remap([1: 11, 2: 12, 4: 14])
        #expect(tabs.groups == [TabGroup(windows: [11, 12], active: 11, frame: frame)])
    }

    @Test func testAdoptingARestoredGroup() {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: frame)
        tabs.adopt(TabGroup(windows: [3, 4], active: 4, frame: frame))
        #expect(tabs.group(containing: 3)?.active == 4)
        // A window already grouped stays put; what's left is too small to be a group.
        tabs.adopt(TabGroup(windows: [2, 5], active: 5, frame: frame))
        #expect(tabs.group(containing: 2)?.windows == [1, 2])
        #expect(tabs.group(containing: 5) == nil)
    }

    @Test func testFrameChanges() {
        let start = Rect(x: 100, y: 100, width: 800, height: 600)
        #expect(FrameChange(from: start, to: Rect(x: 101, y: 99, width: 800.5, height: 600)) == .none)
        #expect(FrameChange(from: start, to: Rect(x: 2267, y: 682, width: 800, height: 600)) == .moved)
        #expect(FrameChange(from: start, to: Rect(x: 60, y: 100, width: 840, height: 600)) == .resized)
    }
}

struct PlacementTests {
    /// The main display's visible frame on the Mac this was tested on.
    let visible = Rect(x: 0, y: 30, width: 2624, height: 1367)

    @Test func testStripSitsAboveTheWindowAndFitsInsideARegion() {
        let half = Rect(x: 0, y: 36, width: 1312, height: 1366)
        let window = TabStripLayout.window(fitting: half, stripHeight: 30)
        #expect(window == Rect(x: 0, y: 66, width: 1312, height: 1336))
        #expect(TabStripLayout.strip(above: window, height: 30) == Rect(x: 0, y: 36, width: 1312, height: 30))
        #expect(TabStripLayout.region(of: window, stripHeight: 30) == half)
    }

    @Test func testTabRects() {
        let strip = Rect(x: 100, y: 0, width: 1000, height: 30)
        #expect(TabStripLayout.tabRects(in: strip, count: 2, maxWidth: 280).map(\.minX) == [100, 380])
        #expect(TabStripLayout.tabRects(in: strip, count: 5, maxWidth: 280).map(\.width) == [200, 200, 200, 200, 200])
        #expect(TabStripLayout.tabIndex(at: 390, in: strip, count: 2, maxWidth: 280) == 1)
        #expect(TabStripLayout.tabIndex(at: 900, in: strip, count: 2, maxWidth: 280) == nil)
        #expect(TabStripLayout.insertionIndex(at: 150, in: strip, count: 2, maxWidth: 280) == 0)
        #expect(TabStripLayout.insertionIndex(at: 300, in: strip, count: 2, maxWidth: 280) == 1)
        #expect(TabStripLayout.insertionIndex(at: 900, in: strip, count: 2, maxWidth: 280) == 2)
    }

    @Test func testSideDetection() {
        // Grid's halves.
        #expect(SideBySide.side(of: Rect(x: 0, y: 36, width: 1312, height: 1366), in: visible) == .left)
        #expect(SideBySide.side(of: Rect(x: 1312, y: 36, width: 1312, height: 1366), in: visible) == .right)
        // Outlook, which won't go narrower than 1368, still keeps its edge.
        #expect(SideBySide.side(of: Rect(x: 0, y: 36, width: 1368, height: 1366), in: visible) == .left)
        #expect(SideBySide.side(of: Rect(x: 1312, y: 36, width: 1368, height: 1366), in: visible) == .right)
        // A right side already narrowed for a wide left.
        #expect(SideBySide.side(of: Rect(x: 1368, y: 36, width: 1256, height: 1366), in: visible) == .right)
        // Not halves: maximised, a quarter, a floating window.
        #expect(SideBySide.side(of: Rect(x: 0, y: 30, width: 2624, height: 1367), in: visible) == nil)
        #expect(SideBySide.side(of: Rect(x: 0, y: 30, width: 1312, height: 683), in: visible) == nil)
        #expect(SideBySide.side(of: Rect(x: 400, y: 200, width: 1200, height: 1100), in: visible) == nil)
    }

    @Test func testDividerGivesAWideAppTheRoomItNeeds() {
        #expect(SideBySide.divider(in: visible, leftNeeds: 0, rightNeeds: 0) == 1312)
        #expect(SideBySide.divider(in: visible, leftNeeds: 1000, rightNeeds: 900) == 1312)
        // Outlook on the left needs 1368: the line moves right.
        #expect(SideBySide.divider(in: visible, leftNeeds: 1368, rightNeeds: 0) == 1368)
        // Outlook on the right: the line moves left.
        #expect(SideBySide.divider(in: visible, leftNeeds: 0, rightNeeds: 1368) == 1256)
        // Both fit, just: each gets its need.
        #expect(SideBySide.divider(in: visible, leftNeeds: 1368, rightNeeds: 1256) == 1368)
        // Both can't fit: shared in proportion to their needs.
        #expect(abs(SideBySide.divider(in: visible, leftNeeds: 1600, rightNeeds: 1600) - 1312) < 1e-9)
        #expect(abs(SideBySide.divider(in: visible, leftNeeds: 2000, rightNeeds: 1000) - 2624 * 2 / 3) < 1e-9)
    }

    @Test func testSideFramesKeepTheirOwnTopAndHeight() {
        let left = Rect(x: 0, y: 36, width: 1368, height: 1366)
        let right = Rect(x: 1312, y: 66, width: 1312, height: 1336)
        #expect(SideBySide.frame(for: .left, keeping: left, in: visible, divider: 1368) == Rect(x: 0, y: 36, width: 1368, height: 1366))
        #expect(SideBySide.frame(for: .right, keeping: right, in: visible, divider: 1368) == Rect(x: 1368, y: 66, width: 1256, height: 1336))
    }
}

struct GeometryTests {
    @Test func testClampedInto() {
        let bounds = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(Rect(x: 90, y: -10, width: 30, height: 30).clamped(into: bounds) == Rect(x: 70, y: 0, width: 30, height: 30))
        #expect(Rect(x: 10, y: 10, width: 300, height: 50).clamped(into: bounds) == Rect(x: 0, y: 10, width: 100, height: 50))
    }

    @Test func testIntersection() {
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        #expect(a.intersection(Rect(x: 50, y: 50, width: 100, height: 100)) == Rect(x: 50, y: 50, width: 50, height: 50))
        #expect(a.intersection(Rect(x: 2623, y: 1331, width: 1368, height: 684)) == .zero)
    }
}
