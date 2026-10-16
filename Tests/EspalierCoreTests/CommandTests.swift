import Foundation
import Testing
@testable import EspalierCore

struct CommandTests {
    @Test func testURLParsing() {
        func parse(_ s: String) -> Command? { Command(url: URL(string: s)!) }
        #expect(parse("espalier://arrange") == .arrange)
        #expect(parse("espalier://back") == .back)
        #expect(parse("espalier://zoom-out") == .zoomOut)
        #expect(parse("ESPALIER://Zoom-Out") == .zoomOut)
        #expect(parse("espalier://view/3") == .view(3))
        #expect(parse("espalier://view?n=4") == .view(4))
        #expect(parse("espalier://save-view/9") == .saveView(9))
        #expect(parse("espalier://focus/left") == .focus(.left))
        #expect(parse("espalier://focus?direction=up") == .focus(.top))
        #expect(parse("espalier://dock/bottom") == .dock(.bottom))
        #expect(parse("espalier://view/10") == nil)
        #expect(parse("espalier://view") == nil)
        #expect(parse("espalier://nonsense") == nil)
        #expect(parse("https://zoom-out") == nil)
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

    @Test func testDefaultBindingsAreValidAndUnique() {
        let (bindings, problems) = Config().bindings()
        #expect(problems == [])
        #expect(bindings.count == Config.defaultHotkeys.count)
        #expect(bindings[Hotkey("ctrl+alt+up")!] == .zoomOut)
        #expect(bindings[Hotkey("ctrl+alt+shift+3")!] == .saveView(3))
    }

    @Test func testUserBindingsOverrideAndDisable() {
        var config = Config()
        config.hotkeys = ["zoom-out": "cmd+alt+up", "back": "", "bogus": "ctrl+x", "forward": "ctrl+alt+nope"]
        let (bindings, problems) = config.bindings()
        #expect(bindings[Hotkey("cmd+alt+up")!] == .zoomOut)
        #expect(bindings[Hotkey("ctrl+alt+up")!] == nil)
        #expect(!bindings.values.contains(.back))
        #expect(problems.count == 2)
    }

    @Test func testConflictingBindingsAreReported() {
        var config = Config()
        config.hotkeys = ["zoom-in": "ctrl+alt+up"]
        let (_, problems) = config.bindings()
        #expect(problems.count == 1)
    }

    @Test func testConfigDecodesPartialFiles() throws {
        let json = #"{"metrics": {"gap": 12}, "docking": false, "excludedBundleIDs": ["com.example"]}"#
        let config = try Config.decode(Data(json.utf8))
        #expect(config.metrics.gap == 12)
        #expect(config.metrics.margin == LayoutMetrics().margin)
        #expect(!config.docking)
        #expect(config.excludedBundleIDs == ["com.example"])
        #expect(config.animationDuration == Config().animationDuration)
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
        let json = #"{"version": 99, "displays": {}}"#
        #expect(throws: (any Error).self) { try WorkspaceSnapshot.decode(Data(json.utf8)) }
    }
}

struct PersistenceTests {
    @Test func testHandEditedLayoutsAreNormalisedOnLoad() throws {
        // A split with one child, a same-axis nested split, no desktop and a duplicate window.
        let json = """
        {"version": 1, "displays": {"main": {
          "layout": {"root": {"type": "split", "id": "a", "axis": "horizontal", "weights": [1, 1], "children": [
            {"type": "group", "id": "g1", "slots": [{"window": 1, "suspended": false}]},
            {"type": "split", "id": "b", "axis": "horizontal", "weights": [1], "children": [
              {"type": "group", "id": "g2", "slots": [{"window": 2, "suspended": false}, {"window": 1, "suspended": false}]}
            ]}
          ]}},
          "navigation": {"current": {"windows": [], "desktop": false, "overview": true}, "back": [], "forward": [], "saved": {}},
          "floating": [],
          "windowInfo": []
        }}}
        """
        let snapshot = try WorkspaceSnapshot.decode(Data(json.utf8))
        #expect(snapshot.displays["main"]?.layout.shape == "row(1,2,D)")
    }
}
