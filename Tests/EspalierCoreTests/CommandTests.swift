import XCTest
@testable import EspalierCore

final class CommandTests: XCTestCase {
    func testURLParsing() {
        func parse(_ s: String) -> Command? { Command(url: URL(string: s)!) }
        XCTAssertEqual(parse("espalier://arrange"), .arrange)
        XCTAssertEqual(parse("espalier://back"), .back)
        XCTAssertEqual(parse("espalier://zoom-out"), .zoomOut)
        XCTAssertEqual(parse("ESPALIER://Zoom-Out"), .zoomOut)
        XCTAssertEqual(parse("espalier://view/3"), .view(3))
        XCTAssertEqual(parse("espalier://view?n=4"), .view(4))
        XCTAssertEqual(parse("espalier://save-view/9"), .saveView(9))
        XCTAssertEqual(parse("espalier://focus/left"), .focus(.left))
        XCTAssertEqual(parse("espalier://focus?direction=up"), .focus(.top))
        XCTAssertEqual(parse("espalier://dock/bottom"), .dock(.bottom))
        XCTAssertNil(parse("espalier://view/10"))
        XCTAssertNil(parse("espalier://view"))
        XCTAssertNil(parse("espalier://nonsense"))
        XCTAssertNil(parse("https://zoom-out"))
    }

    func testEveryCommandRoundTripsThroughItsURLAndName() {
        for command in Command.all {
            XCTAssertEqual(Command(url: command.url), command, command.name)
            XCTAssertEqual(Command(name: command.name), command, command.name)
        }
    }

    func testHotkeyParsing() {
        XCTAssertEqual(Hotkey("ctrl+alt+up"), Hotkey(key: "up", modifiers: [.control, .option]))
        XCTAssertEqual(Hotkey("Cmd + Shift + 3"), Hotkey(key: "3", modifiers: [.command, .shift]))
        XCTAssertEqual(Hotkey("⌃⌥←"), Hotkey(key: "left", modifiers: [.control, .option]))
        XCTAssertEqual(Hotkey("ctrl+alt+]"), Hotkey(key: "]", modifiers: [.control, .option]))
        XCTAssertEqual(Hotkey("ctrl+enter"), Hotkey(key: "return", modifiers: [.control]))
        XCTAssertEqual(Hotkey("f5"), Hotkey(key: "f5", modifiers: []))
        XCTAssertNil(Hotkey("a"), "plain letters need a modifier")
        XCTAssertNil(Hotkey("hyper+a"))
        XCTAssertNil(Hotkey("ctrl+nokey"))
        XCTAssertEqual(Hotkey("ctrl+alt+up")?.description, "⌃⌥↑")
    }

    func testDefaultBindingsAreValidAndUnique() {
        let (bindings, problems) = Config().bindings()
        XCTAssertEqual(problems, [])
        XCTAssertEqual(bindings.count, Config.defaultHotkeys.count)
        XCTAssertEqual(bindings[Hotkey("ctrl+alt+up")!], .zoomOut)
        XCTAssertEqual(bindings[Hotkey("ctrl+alt+shift+3")!], .saveView(3))
    }

    func testUserBindingsOverrideAndDisable() {
        var config = Config()
        config.hotkeys = ["zoom-out": "cmd+alt+up", "back": "", "bogus": "ctrl+x", "forward": "ctrl+alt+nope"]
        let (bindings, problems) = config.bindings()
        XCTAssertEqual(bindings[Hotkey("cmd+alt+up")!], .zoomOut)
        XCTAssertNil(bindings[Hotkey("ctrl+alt+up")!])
        XCTAssertFalse(bindings.values.contains(.back))
        XCTAssertEqual(problems.count, 2)
    }

    func testConflictingBindingsAreReported() {
        var config = Config()
        config.hotkeys = ["zoom-in": "ctrl+alt+up"]
        let (_, problems) = config.bindings()
        XCTAssertEqual(problems.count, 1)
    }

    func testConfigDecodesPartialFiles() throws {
        let json = #"{"metrics": {"gap": 12}, "docking": false, "excludedBundleIDs": ["com.example"]}"#
        let config = try Config.decode(Data(json.utf8))
        XCTAssertEqual(config.metrics.gap, 12)
        XCTAssertEqual(config.metrics.margin, LayoutMetrics().margin)
        XCTAssertFalse(config.docking)
        XCTAssertEqual(config.excludedBundleIDs, ["com.example"])
        XCTAssertEqual(config.animationDuration, Config().animationDuration)
        let roundTrip = try Config.decode(config.encoded())
        XCTAssertEqual(roundTrip, config)
    }

    func testWindowMatching() {
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
        XCTAssertEqual(m, [10: 10, 11: 50, 12: 60])
    }

    func testWindowMatchingDoesNotReuseAnIDForADifferentApp() {
        let m = WindowMatcher.match(saved: [5: WindowInfo(bundleID: "a", title: "x")], live: [5: WindowInfo(bundleID: "b", title: "x")])
        XCTAssertEqual(m, [:])
    }

    func testSnapshotRejectsNewerVersions() {
        let json = #"{"version": 99, "displays": {}}"#
        XCTAssertThrowsError(try WorkspaceSnapshot.decode(Data(json.utf8)))
    }
}

final class PersistenceTests: XCTestCase {
    func testHandEditedLayoutsAreNormalisedOnLoad() throws {
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
        XCTAssertEqual(snapshot.displays["main"]?.layout.shape, "row(1,2,D)")
    }
}
