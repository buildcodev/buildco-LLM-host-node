import Foundation
import Testing
@testable import EspalierCore

struct CommandTests {
    @Test func testURLParsing() {
        func parse(_ s: String) -> Command? { Command(url: URL(string: s)!) }
        #expect(parse("espalier://next-tab") == .nextTab)
        #expect(parse("ESPALIER://Previous-Tab") == .previousTab)
        #expect(parse("espalier://tab/3") == .tab(3))
        #expect(parse("espalier://tab?n=4") == .tab(4))
        #expect(parse("espalier://ungroup") == .ungroup)
        #expect(parse("espalier://ungroup-all") == .ungroupAll)
        #expect(parse("espalier://tab/10") == nil)
        #expect(parse("espalier://tab") == nil)
        #expect(parse("espalier://zoom-out") == nil)
        #expect(parse("https://next-tab") == nil)
    }

    @Test func testEveryCommandRoundTripsThroughItsURLAndName() {
        for command in Command.all {
            #expect(Command(url: command.url) == command, "\(command.name)")
            #expect(Command(name: command.name) == command, "\(command.name)")
        }
    }

    @Test func testHotkeyParsing() {
        #expect(Hotkey("ctrl+alt+up") == Hotkey(key: "up", modifiers: [.control, .option]))
        #expect(Hotkey("Cmd + Shift + 3") == Hotkey(key: "3", modifiers: [.command, .shift]))
        #expect(Hotkey("⌃⌥←") == Hotkey(key: "left", modifiers: [.control, .option]))
        #expect(Hotkey("ctrl+alt+]") == Hotkey(key: "]", modifiers: [.control, .option]))
        #expect(Hotkey("ctrl+enter") == Hotkey(key: "return", modifiers: [.control]))
        #expect(Hotkey("f5") == Hotkey(key: "f5", modifiers: []))
        #expect(Hotkey("a") == nil, "plain letters need a modifier")
        #expect(Hotkey("hyper+a") == nil)
        #expect(Hotkey("ctrl+nokey") == nil)
        #expect(Hotkey("ctrl+alt+up")?.description == "⌃⌥↑")
    }

    @Test func testDefaultBindingsAreValidAndClearOfGrid() {
        let (bindings, problems) = Config().bindings()
        #expect(problems == [])
        #expect(bindings[Hotkey("ctrl+alt+]")!] == .nextTab)
        #expect(bindings[Hotkey("ctrl+alt+[")!] == .previousTab)
        // Grid uses ⌃⌥ with arrows, Return and letters.
        #expect(bindings.keys.allSatisfy { !["up", "down", "left", "right", "return"].contains($0.key) && $0.key.count == 1 && !$0.key.first!.isLetter })
    }

    @Test func testUserBindingsOverrideAndDisable() {
        var config = Config()
        config.hotkeys = ["next-tab": "cmd+alt+]", "previous-tab": "", "bogus": "ctrl+x", "ungroup": "ctrl+alt+nope"]
        let (bindings, problems) = config.bindings()
        #expect(bindings[Hotkey("cmd+alt+]")!] == .nextTab)
        #expect(bindings[Hotkey("ctrl+alt+]")!] == nil)
        #expect(!bindings.values.contains(.previousTab))
        #expect(problems.count == 2)
    }

    @Test func testConflictingBindingsAreReported() {
        var config = Config()
        config.hotkeys = ["ungroup": "ctrl+alt+]"]
        let (_, problems) = config.bindings()
        #expect(problems.count == 1)
    }

    @Test func testConfigDecodesPartialFiles() throws {
        let json = #"{"stripHeight": 26, "widenSides": false, "excludedBundleIDs": ["com.example"]}"#
        let config = try Config.decode(Data(json.utf8))
        #expect(config.stripHeight == 26)
        #expect(!config.widenSides)
        #expect(config.excludedBundleIDs == ["com.example"])
        #expect(config.holdDelay == Config().holdDelay)
        let roundTrip = try Config.decode(config.encoded())
        #expect(roundTrip == config)
    }

    @Test func testWindowMatching() {
        let saved: [WindowID: WindowInfo] = [
            10: WindowInfo(bundleID: "a", title: "One"),
            11: WindowInfo(bundleID: "a", title: "Two"),
            12: WindowInfo(bundleID: "b", title: "Mail"),
            13: WindowInfo(bundleID: "c", title: "Gone"),
        ]
        let live: [WindowID: WindowInfo] = [
            10: WindowInfo(bundleID: "a", title: "One (edited)"), // same id: exact match despite new title
            50: WindowInfo(bundleID: "a", title: "Two"),           // relaunched: title match
            60: WindowInfo(bundleID: "b", title: "Inbox"),         // relaunched: app match
            70: WindowInfo(bundleID: "d", title: "New"),
        ]
        let m = WindowMatcher.match(saved: saved, live: live)
        #expect(m == [10: 10, 11: 50, 12: 60])
    }

    @Test func testWindowMatchingDoesNotReuseAnIDForADifferentApp() {
        let m = WindowMatcher.match(saved: [5: WindowInfo(bundleID: "a", title: "x")], live: [5: WindowInfo(bundleID: "b", title: "x")])
        #expect(m == [:])
    }

    @Test func testSnapshotRejectsNewerVersions() {
        let json = #"{"version": 99}"#
        #expect(throws: (any Error).self) { try TabsSnapshot.decode(Data(json.utf8)) }
    }

    @Test func testSnapshotRoundTrip() throws {
        var tabs = TabGroups()
        tabs.add(2, to: 1, frame: Rect(x: 0, y: 60, width: 1312, height: 1342))
        let snapshot = TabsSnapshot(tabs: tabs, windowInfo: [1: WindowInfo(bundleID: "a", title: "x")], minimumWidths: ["com.microsoft.Outlook": 1368])
        #expect(try TabsSnapshot.decode(snapshot.encoded()) == snapshot)
    }

    @Test func testHandEditedGroupsAreCleanedUpOnLoad() throws {
        // Window 1 is in two groups, 3 is listed twice, and one group has a single window.
        let json = """
        {"version": 1, "tabs": {"groups": [
          {"windows": [1, 2], "active": 9, "frame": {"x": 0, "y": 0, "width": 10, "height": 10}},
          {"windows": [1, 3, 3, 4], "active": 4, "frame": {"x": 0, "y": 0, "width": 10, "height": 10}},
          {"windows": [5], "active": 5, "frame": {"x": 0, "y": 0, "width": 10, "height": 10}}
        ]}}
        """
        let snapshot = try TabsSnapshot.decode(Data(json.utf8))
        #expect(snapshot.tabs.groups.map(\.windows) == [[1, 2], [3, 4]])
        #expect(snapshot.tabs.groups[0].active == 1)
        #expect(snapshot.windowInfo.isEmpty && snapshot.minimumWidths.isEmpty)
    }
}
