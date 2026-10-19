#if os(macOS)
import AppKit
import EspalierCore

/// A press on a window that may turn into a drag onto another window's title bar.
private struct DragSession {
    let window: WindowID
    let startFrame: Rect
    var moving = false
    /// The window is a group's shown tab, so its strip follows it.
    var followsStrip = false
    var lastCheck: CFTimeInterval = 0
}

/// Where a dragged window would become a tab, and since when it has hovered there.
private struct Hover {
    var target: WindowID
    var since: CFTimeInterval
    var armed = false
}

/// Keeps tab groups together. Another tool (such as Grid) or the user places a group's shown
/// window; the strip follows it, and whichever tab is chosen takes its place. The other tabs
/// wait off screen. When two windows are snapped side by side and one needs more than half
/// the width, its side gets the room and the other side narrows.
final class TabManager: NSObject {
    private(set) var config = Config()
    private(set) var problems: [String] = []
    private(set) var started = false
    var onChange: (() -> Void)?

    private let store: StateStore
    private let tracker = WindowTracker()
    private let eventTap = EventTap()
    private let hotkeys = HotkeyCenter()
    private let appearance = AppearanceCache()
    private let highlight = DropHighlight()

    private var tabs = TabGroups()
    private var windowInfo: [WindowID: WindowInfo] = [:]
    /// Saved groups whose windows aren't all seen yet (see `restorePending`).
    private var pendingGroups: [TabGroup] = []
    private var pendingInfo: [WindowID: WindowInfo] = [:]
    /// The narrowest each app's windows will go, by bundle id.
    private var minimumWidths: [String: Double] = [:]
    private var displays: [Display] = []
    /// Each grouped window maps to its group's strip.
    private var strips: [WindowID: StripPanel] = [:]
    /// The window (or a window of the group) snapped to each half of each display.
    private var sides: [String: [Side: WindowID]] = [:]

    private var parked: Set<WindowID> = []
    private var minimized: Set<WindowID> = []
    private var lastSet: [WindowID: CFTimeInterval] = [:]
    private var settleItems: [WindowID: DispatchWorkItem] = [:]
    private var drag: DragSession?
    private var hover: Hover?
    private var restoring = false
    /// Focus changes until then come from showing a tab ourselves, not from Cmd-Tab or the Dock.
    private var showingUntil: CFTimeInterval = 0
    private var saveItem: DispatchWorkItem?
    private var timer: Timer?

    init(store: StateStore) {
        self.store = store
        super.init()
        let (config, problem) = store.loadConfig()
        self.config = config
        if let problem { problems = [problem] }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        tracker.excludedBundleIDs = Set(config.excludedBundleIDs)
        // A hung app must not stall Espalier (and with it the event tap).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        tracker.delegate = self
        eventTap.handler = self
        if !eventTap.start() { problems.append("Couldn't watch the mouse: dragging onto title bars won't make tabs") }
        hotkeys.onCommand = { [weak self] command in self?.perform(command) }
        registerHotkeys()
        displays = Displays.all()
        restoring = true
        tracker.start()
        restore()
        restoring = false

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.syncStrips() }
        logger.info("Started with \(self.tabs.groups.count) tab group(s) and \(self.tracker.windows.count) window(s)")
        onChange?()
    }

    /// Saves, then puts every hidden tab back on screen in its group's place so nothing is
    /// lost when Espalier quits.
    func stop() {
        guard started else { return }
        saveNow()
        for g in tabs.groups {
            for id in g.hidden where !minimized.contains(id) { setFrame(id, g.frame) }
            tracker.windows[g.active]?.element.raise()
        }
        parked.removeAll()
        for panel in Set(strips.values) { panel.close() }
        strips.removeAll()
        highlight.show(nil)
        eventTap.stop()
        hotkeys.unregisterAll()
        tracker.stop()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        started = false
    }

    func reloadConfig() {
        let (config, problem) = store.loadConfig()
        self.config = config
        problems = problem.map { [$0] } ?? []
        tracker.excludedBundleIDs = Set(config.excludedBundleIDs)
        guard started else { return }
        registerHotkeys()
        for g in tabs.groups { show(g.active, focus: false) }
    }

    /// The shortcut for each command, for menus.
    var shortcuts: [Command: Hotkey] {
        var result: [Command: Hotkey] = [:]
        for (hotkey, command) in config.bindings().bindings { result[command] = hotkey }
        return result
    }

    var groupCount: Int { tabs.groups.count }

    private func registerHotkeys() {
        let (bindings, bindingProblems) = config.bindings()
        let registrationProblems = hotkeys.register(bindings)
        problems = Array(Set(problems + bindingProblems + registrationProblems)).sorted()
        for problem in problems { logger.warning("\(problem, privacy: .public)") }
    }

    private func restore() {
        let snapshot = store.loadSnapshot()
        minimumWidths = snapshot?.minimumWidths ?? [:]
        for window in tracker.windows.values where window.isMinimized { minimized.insert(window.id) }
        pendingGroups = snapshot?.tabs.groups ?? []
        pendingInfo = snapshot?.windowInfo ?? [:]
        restorePending()
        // A window left off screen by a crash comes back.
        for w in tracker.windows.values where !tabs.allWindows.contains(w.id) && !isPending(w.id) {
            if let frame = w.frame { rescueIfStranded(w, frame: frame) }
        }
        syncStrips()
    }

    private func isPending(_ id: WindowID) -> Bool {
        pendingGroups.contains { $0.windows.contains(id) }
    }

    /// Brings back saved groups once all their windows are accounted for. Accessibility only
    /// sees windows on the Spaces being shown, so a window the window server still has (on
    /// another Space) is waited for. A window that's gone is matched by app and title, for an
    /// app that restarted, or dropped.
    private func restorePending() {
        guard !pendingGroups.isEmpty else { return }
        let existing = WindowList.allIDs()
        var waiting: [TabGroup] = []
        for saved in pendingGroups {
            if saved.windows.contains(where: { tracker.windows[$0] == nil && existing.contains($0) }) {
                waiting.append(saved)
                continue
            }
            let gone = Set(saved.windows.filter { tracker.windows[$0] == nil })
            let candidates = tracker.windows.filter { !tabs.allWindows.contains($0.key) && !isPending($0.key) }.mapValues(\.info)
            let matched = WindowMatcher.match(saved: pendingInfo.filter { gone.contains($0.key) }, live: candidates)
            var mapping: [WindowID: WindowID] = [:]
            for id in saved.windows { mapping[id] = gone.contains(id) ? matched[id] : id }
            var one = TabGroups(groups: [saved])
            one.remap(mapping)
            guard let g = one.groups.first else { continue }
            tabs.adopt(g)
            guard tabs.group(containing: g.active) != nil else { continue }
            tabs.setFrame(roomForStrip(tabs.group(containing: g.active)!.frame), ofGroupContaining: g.active)
            let adopted = tabs.group(containing: g.active)!
            logger.info("Restored a group of \(adopted.windows.count) tabs")
            for id in adopted.windows { windowInfo[id] = tracker.windows[id]?.info }
            if !minimized.contains(adopted.active) { setFrame(adopted.active, adopted.frame) }
            for id in adopted.hidden where !minimized.contains(id) { park(id) }
        }
        pendingGroups = waiting
        if !waiting.isEmpty { logger.info("\(waiting.count) saved group(s) wait for windows on other Spaces") }
        syncStrips()
        scheduleSave()
    }

    // MARK: Showing tabs

    /// Shows `window`'s tab in its group's place and hides the tab that was shown.
    private func show(_ window: WindowID, focus: Bool) {
        guard var g = tabs.group(containing: window) else { return }
        let room = roomForStrip(g.frame)
        if room != g.frame {
            tabs.setFrame(room, ofGroupContaining: window)
            g.frame = room
        }
        let previous = tabs.activate(window)
        showingUntil = CACurrentMediaTime() + 0.5
        minimized.remove(window)
        setFrame(window, g.frame)
        if let previous, previous != window, !minimized.contains(previous) { park(previous) }
        if focus { self.focus(window) } else { tracker.windows[window]?.element.raise() }
        verifyPlacement(of: window)
        logger.debug("Showing tab \(window) (hid \(previous ?? 0))")
        rebalance(containing: window)
        syncStrips()
        scheduleSave()
    }

    private func focus(_ id: WindowID) {
        guard let w = tracker.windows[id] else { return }
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        w.element.set(kAXMainAttribute, kCFBooleanTrue)
        w.element.raise()
    }

    /// Puts a hidden tab almost entirely off screen, in a corner of its group's display.
    private func park(_ id: WindowID) {
        guard let w = tracker.windows[id], let g = tabs.group(containing: id),
              let display = displays.best(for: g.frame)
        else { return }
        let size = w.element.size ?? CGSize(width: g.frame.width, height: g.frame.height)
        lastSet[id] = CACurrentMediaTime()
        w.element.setPosition(display.parkingOrigin(for: size, among: displays))
        parked.insert(id)
    }

    /// Moves a window and returns where it ended up. A window that won't get as narrow as
    /// asked teaches its app's minimum width.
    @discardableResult
    private func setFrame(_ id: WindowID, _ frame: Rect) -> Rect? {
        guard let w = tracker.windows[id] else { return nil }
        parked.remove(id)
        lastSet[id] = CACurrentMediaTime()
        withoutEnhancedUserInterface(pid: w.pid) { w.element.setFrame(frame.cgRect) }
        guard let actual = w.frame else { return nil }
        if actual.width > frame.width + 4, (minimumWidths[w.bundleID] ?? 0) < actual.width {
            logger.info("\(w.bundleID, privacy: .public) won't go narrower than \(actual.width, privacy: .public)")
            minimumWidths[w.bundleID] = actual.width
            scheduleSave()
        }
        return actual
    }

    /// Apps with AXEnhancedUserInterface on (set by assistive tools) animate every frame
    /// change; turning it off briefly makes moves instant.
    private func withoutEnhancedUserInterface(pid: pid_t, _ body: () -> Void) {
        let app = AXUIElementCreateApplication(pid)
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        body()
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
    }

    /// A window that arrives almost entirely off screen, like a hidden tab when Espalier
    /// crashed or was force quit, is moved back into view so it can't be lost.
    private func rescueIfStranded(_ w: TrackedWindow, frame: Rect) {
        guard let display = displays.best(for: frame) else { return }
        let visible = frame.intersection(display.visibleFrame)
        guard visible.width < 40 || visible.height < 40 else { return }
        let rescued = frame.clamped(into: display.visibleFrame)
        logger.info("Bringing stranded window \(w.id) back on screen at \(rescued, privacy: .public)")
        setFrame(w.id, rescued)
    }

    // MARK: Strips

    /// Puts each group's strip above its shown window, or hides it when that window isn't on screen.
    private func syncStrips() {
        guard started else { return }
        let onScreen = WindowList.onScreenIDs()
        var used = Set<ObjectIdentifier>()
        var next: [WindowID: StripPanel] = [:]
        for g in tabs.groups {
            let panel = g.windows.lazy.compactMap { self.strips[$0] }.first { !used.contains(ObjectIdentifier($0)) } ?? makeStrip()
            used.insert(ObjectIdentifier(panel))
            for id in g.windows { next[id] = panel }
            let view = panel.stripView
            view.tabs = g.windows
            view.active = g.active
            view.maxTabWidth = config.maxTabWidth
            view.needsDisplay = true
            guard onScreen.contains(g.active), !minimized.contains(g.active), let frame = tracker.windows[g.active]?.frame else {
                panel.orderOut(nil)
                continue
            }
            panel.show(at: TabStripLayout.strip(above: frame, height: config.stripHeight), above: g.active)
        }
        for panel in Set(strips.values) where !used.contains(ObjectIdentifier(panel)) { panel.close() }
        strips = next
    }

    /// Moves one group's strip to follow its shown window, without redrawing the others.
    private func followStrip(of id: WindowID, frame: Rect) {
        guard let panel = strips[id], tabs.group(containing: id)?.active == id else { return }
        panel.show(at: TabStripLayout.strip(above: frame, height: config.stripHeight), above: id, restack: false)
    }

    /// Apps sometimes put a window back where they had it just after we move it (Teams
    /// finishing its own title-bar drag, for one). Checks a moment later and, if the shown
    /// tab has wandered from its group's place, puts it back once. A window that's only
    /// wider (an app's minimum) has stayed put.
    private func verifyPlacement(of id: WindowID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.drag == nil, NSEvent.pressedMouseButtons & 1 == 0,
                  let g = self.tabs.group(containing: id), g.active == id, !self.minimized.contains(id),
                  let frame = self.tracker.windows[id]?.frame
            else { return }
            let wandered = abs(frame.x - g.frame.x) > 2 || abs(frame.y - g.frame.y) > 2
                || abs(frame.height - g.frame.height) > 2 || frame.width < g.frame.width - 2
            guard wandered else { return }
            logger.info("Tab \(id) moved off its place to \(frame, privacy: .public); putting it back")
            if let actual = self.setFrame(id, g.frame) { self.followStrip(of: id, frame: actual) }
        }
    }

    private func makeStrip() -> StripPanel {
        let panel = StripPanel()
        let view = panel.stripView
        view.look = { [weak self] id in self?.look(id) }
        view.onSelect = { [weak self] id in self?.show(id, focus: true) }
        view.onReorder = { [weak self] id, index in
            self?.tabs.move(id, to: index)
            self?.syncStrips()
            self?.scheduleSave()
        }
        view.onTearOff = { [weak self] id, point in self?.tearOff(id, at: point) }
        view.onClose = { [weak self] id, quitApp in self?.close(id, quitApp: quitApp) }
        return panel
    }

    private func look(_ id: WindowID) -> WindowLook? {
        guard let w = tracker.windows[id] else { return nil }
        return WindowLook(color: appearance.color(bundleID: w.bundleID, pid: w.pid), icon: appearance.icon(pid: w.pid), title: w.title)
    }

    // MARK: Grouping

    /// Where a dragged window let go at `p` would become a tab: a strip, or the top of the
    /// frontmost window under the pointer (its title bar and a little below, `dropZoneHeight`).
    private func dropTarget(at p: Point, excluding dragged: WindowID) -> WindowID? {
        let ownGroup = tabs.group(containing: dragged)?.windows ?? [dragged]
        let pid = getpid()
        for entry in WindowList.onScreen() where entry.layer == 0 && Rect(entry.bounds).contains(p) {
            if entry.pid == pid {
                // One of our strips, or the highlight.
                guard let panel = strips.values.first(where: { $0.windowNumber == Int(entry.id) }),
                      let g = tabs.groups.first(where: { strips[$0.active] === panel })
                else { continue }
                return ownGroup.contains(g.active) ? nil : g.active
            }
            if entry.id == dragged { continue }
            guard tracker.windows[entry.id] != nil, !ownGroup.contains(entry.id) else { return nil }
            return p.y - Double(entry.bounds.minY) < config.dropZoneHeight ? entry.id : nil
        }
        return nil
    }

    /// The outline for a drop target: its strip and the top of the window, the area where
    /// letting go makes a tab.
    private func highlightRect(for target: WindowID) -> Rect? {
        guard let frame = tracker.windows[target]?.frame else { return nil }
        let titleBar = Rect(x: frame.x, y: frame.y, width: frame.width, height: min(config.dropZoneHeight, frame.height))
        guard tabs.group(containing: target) != nil else { return titleBar }
        return TabStripLayout.strip(above: frame, height: config.stripHeight).union(titleBar)
    }

    /// The frame a group around a lone `target` window takes: where it is, giving up the
    /// top of its frame to the strip when the strip wouldn't fit above it.
    private func groupFrame(around target: WindowID) -> Rect? {
        if let g = tabs.group(containing: target) { return g.frame }
        guard let frame = tracker.windows[target]?.frame else { return nil }
        return fitted(frame)
    }

    /// A group's frame moved down just enough for its strip to fit below the top of the
    /// screen, keeping its bottom edge. Needed when the strip got taller in the settings.
    private func roomForStrip(_ frame: Rect) -> Rect {
        guard let display = displays.best(for: frame) else { return frame }
        let overflow = display.visibleFrame.minY - (frame.minY - config.stripHeight)
        guard overflow > 0.5 else { return frame }
        return Rect(x: frame.x, y: frame.y + overflow, width: frame.width, height: max(100, frame.height - overflow))
    }

    private func fitted(_ frame: Rect) -> Rect {
        guard let display = displays.best(for: frame) else { return frame }
        let strip = TabStripLayout.strip(above: frame, height: config.stripHeight)
        return strip.minY < display.visibleFrame.minY - 1 ? TabStripLayout.window(fitting: frame, stripHeight: config.stripHeight) : frame
    }

    /// Makes `window` a tab in `target`'s group (or a new group with `target`), and shows it.
    private func group(_ window: WindowID, onto target: WindowID, at index: Int? = nil) {
        guard let frame = groupFrame(around: target) else { return }
        detach(window)
        let hidden = tabs.add(window, to: target, frame: frame, at: index)
        for id in [window, target] { windowInfo[id] = tracker.windows[id]?.info }
        logger.info("Tabbed \(window) with \(target)")
        setFrame(window, frame)
        if let hidden, !minimized.contains(hidden) { park(hidden) }
        focus(window)
        verifyPlacement(of: window)
        rebalance(containing: window)
        syncStrips()
        scheduleSave()
    }

    /// Takes a window out of its group; the group shows another tab in its place if needed.
    private func detach(_ window: WindowID) {
        guard let removal = tabs.remove(window) else { return }
        windowInfo[window] = nil
        if let shown = removal.shown, !minimized.contains(shown) {
            setFrame(shown, removal.frame)
            tracker.windows[shown]?.element.raise()
        }
        if let lone = removal.dissolved {
            windowInfo[lone] = nil
            // The window left on its own keeps the group's place, strip room included.
            if !minimized.contains(lone) {
                setFrame(lone, TabStripLayout.region(of: removal.frame, stripHeight: config.stripHeight))
            }
        }
    }

    /// A tab's × was clicked: closes its window, like closing a browser tab. With ⌥, quits
    /// the window's app instead.
    private func close(_ id: WindowID, quitApp: Bool) {
        guard let w = tracker.windows[id] else { return }
        if quitApp {
            logger.info("Quitting \(w.bundleID, privacy: .public) from its tab")
            NSRunningApplication(processIdentifier: w.pid)?.terminate()
            return
        }
        // A waiting tab is shown first, so whatever the app asks before closing (unsaved
        // changes, for one) appears where it can be seen.
        if tabs.isHidden(id) { show(id, focus: true) }
        logger.info("Closing tab \(id)")
        if let button = w.element.element(kAXCloseButtonAttribute),
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            return
        }
        // No close button to press: ask the app the way its File menu would, with ⌘W.
        focus(id)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: down) // W
            event?.flags = .maskCommand
            event?.postToPid(w.pid)
        }
    }

    /// A tab dragged off its strip: it joins whatever it was let go over, or floats there.
    private func tearOff(_ window: WindowID, at point: Point) {
        guard let g = tabs.group(containing: window) else { return }
        if let target = dropTarget(at: point, excluding: window) {
            group(window, onto: target)
            return
        }
        detach(window)
        let size = g.frame.size
        var frame = Rect(x: point.x - size.width / 2, y: point.y - 12, width: size.width, height: size.height)
        if let display = displays.best(for: frame) { frame = frame.clamped(into: display.visibleFrame) }
        logger.info("Tore \(window) off its strip")
        setFrame(window, frame)
        focus(window)
        syncStrips()
        scheduleSave()
    }

    private func finishDrag(_ session: DragSession, at point: Point) {
        let armed = hover.flatMap { $0.armed ? $0.target : nil }
        hover = nil
        highlight.show(nil)
        if let target = armed, target == dropTarget(at: point, excluding: session.window) {
            group(session.window, onto: target)
            return
        }
        // The shown tab was moved or resized by hand: the group follows it.
        guard let g = tabs.group(containing: session.window), g.active == session.window,
              let frame = tracker.windows[session.window]?.frame
        else { return }
        var settled = frame
        if let display = displays.best(for: frame), frame.minY - config.stripHeight < display.visibleFrame.minY {
            settled.y = display.visibleFrame.minY + config.stripHeight
            setFrame(session.window, settled)
        }
        tabs.setFrame(settled, ofGroupContaining: session.window)
        followStrip(of: session.window, frame: settled)
        scheduleSave()
    }

    private func updateHover(_ session: DragSession, at point: Point) {
        let target = dropTarget(at: point, excluding: session.window)
        guard target != hover?.target else { return }
        highlight.show(nil)
        guard let target else {
            hover = nil
            return
        }
        hover = Hover(target: target, since: CACurrentMediaTime())
        logger.debug("Dragging \(session.window) over \(target)'s title bar")
        // Arm after hovering a moment, even if the mouse stops moving.
        DispatchQueue.main.asyncAfter(deadline: .now() + config.holdDelay) { [weak self] in
            guard let self, self.drag != nil, self.hover?.target == target else { return }
            logger.debug("Letting go of \(session.window) now makes it a tab with \(target)")
            self.hover?.armed = true
            self.highlight.show(self.highlightRect(for: target))
        }
    }

    // MARK: Side by side

    /// The space a window (or its group, strip included) takes on screen.
    private func region(of id: WindowID) -> Rect? {
        let shown = tabs.group(containing: id)?.active ?? id
        guard !parked.contains(shown), !minimized.contains(shown), let frame = tracker.windows[shown]?.frame else { return nil }
        return tabs.group(containing: id) != nil ? TabStripLayout.region(of: frame, stripHeight: config.stripHeight) : frame
    }

    /// The width the window shown in `id`'s place needs.
    private func need(of id: WindowID) -> Double {
        let shown = tabs.group(containing: id)?.active ?? id
        guard let w = tracker.windows[shown] else { return 0 }
        return minimumWidths[w.bundleID] ?? 0
    }

    /// Something other than the user placed a window (or group): if it was snapped to half
    /// a display, remember that, and widen whichever side needs it.
    private func noteSnap(_ id: WindowID) {
        guard config.widenSides, let region = region(of: id), let display = displays.best(for: region),
              let side = SideBySide.side(of: region, in: display.visibleFrame)
        else { return }
        // An app that stayed wider than the half it was given won't go narrower.
        let shown = tabs.group(containing: id)?.active ?? id
        if let w = tracker.windows[shown], region.width > display.visibleFrame.width / 2 + 4,
           region.width > (minimumWidths[w.bundleID] ?? 0) {
            minimumWidths[w.bundleID] = region.width
            logger.info("\(w.bundleID, privacy: .public) needs \(region.width, privacy: .public) of a half")
        }
        sides[display.uuid, default: [:]][side] = id
        rebalance(display)
    }

    /// After a group shows another tab (which may need a different width), if it sits in
    /// half a display, shares the width again.
    private func rebalance(containing id: WindowID) {
        guard config.widenSides, let region = region(of: id), let display = displays.best(for: region),
              let side = SideBySide.side(of: region, in: display.visibleFrame)
        else { return }
        sides[display.uuid, default: [:]][side] = id
        rebalance(display)
    }

    /// Moves the line between a display's two halves so a side that needs more than half
    /// gets it, and narrows the other side to match.
    private func rebalance(_ display: Display, again: Bool = true) {
        let visible = display.visibleFrame
        var occupants: [Side: (id: WindowID, region: Rect)] = [:]
        for side in Side.allCases {
            guard let id = sides[display.uuid]?[side] else { continue }
            if let region = region(of: id), SideBySide.side(of: region, in: visible) == side {
                occupants[side] = (id, region)
            } else {
                sides[display.uuid]?[side] = nil
            }
        }
        // A window already sitting in the other half (snapped before, or by hand) counts too.
        for side in Side.allCases where occupants[side] == nil {
            if let found = frontmost(snappedTo: side, on: display, excluding: Set(occupants.values.map(\.id))) {
                occupants[side] = found
                sides[display.uuid, default: [:]][side] = found.id
            }
        }
        guard !occupants.isEmpty else { return }
        let divider = SideBySide.divider(in: visible, leftNeeds: occupants[.left].map { need(of: $0.id) } ?? 0,
                                         rightNeeds: occupants[.right].map { need(of: $0.id) } ?? 0)
        let learnedBefore = minimumWidths
        for (side, occupant) in occupants {
            let target = SideBySide.frame(for: side, keeping: occupant.region, in: visible, divider: divider)
            guard !target.isApproximatelyEqual(to: occupant.region, tolerance: 2) else { continue }
            logger.info("Side \(side.rawValue, privacy: .public) of \(display.uuid, privacy: .public) → \(target, privacy: .public)")
            place(occupant.id, region: target)
        }
        // A window that refused its new width taught us its minimum: share again once.
        if again, minimumWidths != learnedBefore { rebalance(display, again: false) }
    }

    /// The frontmost window or group snapped to `side`, by its place on screen.
    private func frontmost(snappedTo side: Side, on display: Display, excluding: Set<WindowID>) -> (id: WindowID, region: Rect)? {
        for entry in WindowList.onScreen() where entry.layer == 0 {
            guard let w = tracker.windows[entry.id], !excluding.contains(w.id), !parked.contains(w.id),
                  !tabs.isHidden(w.id), let region = region(of: w.id)
            else { continue }
            if displays.best(for: region)?.uuid == display.uuid, SideBySide.side(of: region, in: display.visibleFrame) == side {
                return (w.id, region)
            }
        }
        return nil
    }

    /// Puts a window, or a group with its strip, in `region`.
    private func place(_ id: WindowID, region: Rect) {
        if let g = tabs.group(containing: id) {
            let frame = TabStripLayout.window(fitting: region, stripHeight: config.stripHeight)
            tabs.setFrame(frame, ofGroupContaining: id)
            if let actual = setFrame(g.active, frame) { followStrip(of: g.active, frame: actual) }
        } else {
            setFrame(id, region)
        }
        scheduleSave()
    }

    // MARK: Following other tools

    /// Something other than a drag we followed moved or resized a window: Grid, the app,
    /// macOS. Acts once the moves stop, since tools set position and size separately.
    private func settle(_ id: WindowID) {
        guard started, let frame = tracker.windows[id]?.frame else { return }
        if let g = tabs.group(containing: id) {
            guard g.active == id, !parked.contains(id) else { return }
            // When the strip doesn't fit above (Grid's halves and maximize start at the top of
            // the screen), the window gives up the top of its space to the strip so the two
            // together fill it. Once fitted, the strip fits, so this never shrinks it twice.
            let target = fitted(frame)
            tabs.setFrame(target, ofGroupContaining: id)
            if !target.isApproximatelyEqual(to: frame, tolerance: 1), let actual = setFrame(id, target) {
                followStrip(of: id, frame: actual)
            }
            scheduleSave()
        }
        noteSnap(id)
    }

    // MARK: Saving

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func saveNow() {
        saveItem?.cancel()
        for id in tabs.allWindows {
            if let w = tracker.windows[id] { windowInfo[id] = w.info }
        }
        windowInfo = windowInfo.filter { tabs.allWindows.contains($0.key) }
        // Groups still waiting for their windows are kept for next time.
        var info = windowInfo
        for g in pendingGroups { for id in g.windows { info[id] = pendingInfo[id] } }
        let all = TabGroups(groups: tabs.groups + pendingGroups)
        store.save(TabsSnapshot(tabs: all, windowInfo: info, minimumWidths: minimumWidths))
        onChange?()
    }

    // MARK: Commands

    func perform(_ command: Command) {
        guard started else {
            logger.info("Ignoring \(command.name, privacy: .public): not running yet")
            return
        }
        let focused = tracker.frontmostWindow
        switch command {
        case .nextTab, .previousTab:
            guard let focused, let next = tabs.neighbour(of: focused, forward: command == .nextTab) else { return }
            show(next, focus: true)
        case .tab(let n):
            guard let focused, let g = tabs.group(containing: focused), g.windows.indices.contains(n - 1) else { return }
            show(g.windows[n - 1], focus: true)
        case .ungroup:
            guard let focused, let g = tabs.group(containing: focused) else { return }
            detach(focused)
            // Step it aside so the group and the window are both visible.
            setFrame(focused, Rect(x: g.frame.x + 40, y: g.frame.y + 40, width: g.frame.width, height: g.frame.height))
            focus(focused)
            syncStrips()
            scheduleSave()
        case .ungroupAll:
            for g in tabs.groups {
                for (i, id) in g.windows.enumerated() where !minimized.contains(id) {
                    let offset = Double(i) * 40
                    setFrame(id, Rect(x: g.frame.x + offset, y: g.frame.y + offset, width: g.frame.width, height: g.frame.height))
                }
            }
            tabs = TabGroups()
            windowInfo.removeAll()
            syncStrips()
            scheduleSave()
        }
    }

    // MARK: Displays and Spaces

    @objc private func screensChanged() {
        displays = Displays.all()
        for g in tabs.groups { for id in g.hidden where parked.contains(id) { park(id) } }
        syncStrips()
    }

    @objc private func spaceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.syncStrips() }
    }
}

// MARK: - Window events

extension TabManager: WindowTrackerDelegate {
    func trackerAdded(_ window: TrackedWindow) {
        guard started else { return }
        if window.isMinimized { minimized.insert(window.id) }
        guard !restoring else { return }
        // A window on a Space the user just came to may complete a saved group.
        if isPending(window.id) { restorePending() }
        if !tabs.allWindows.contains(window.id), !isPending(window.id), let frame = window.frame {
            rescueIfStranded(window, frame: frame)
        }
    }

    func trackerRemoved(_ id: WindowID) {
        if tabs.group(containing: id) != nil {
            logger.info("Tab \(id) closed")
            detach(id)
        }
        for uuid in Array(sides.keys) {
            for side in Side.allCases where sides[uuid]?[side] == id { sides[uuid]?[side] = nil }
        }
        parked.remove(id)
        minimized.remove(id)
        lastSet[id] = nil
        settleItems.removeValue(forKey: id)?.cancel()
        if drag?.window == id {
            drag = nil
            hover = nil
            highlight.show(nil)
        }
        syncStrips()
        scheduleSave()
    }

    func trackerMinimized(_ id: WindowID, _ isMinimized: Bool) {
        if isMinimized {
            minimized.insert(id)
            // The shown tab went to the Dock: show its neighbour in its place.
            if let g = tabs.group(containing: id), g.active == id,
               let next = g.windows.first(where: { $0 != id && !minimized.contains($0) }) {
                show(next, focus: false)
            }
        } else {
            minimized.remove(id)
            // Back from the Dock: it's the tab shown again.
            if tabs.group(containing: id) != nil { show(id, focus: true) }
        }
        syncStrips()
    }

    func trackerFrameChanged(_ id: WindowID) {
        guard started, let frame = tracker.windows[id]?.frame else { return }
        if tabs.group(containing: id)?.active == id, !parked.contains(id) { followStrip(of: id, frame: frame) }
        // Our own moves, and the user's drags and resizes (handled when the mouse is let go), aren't followed.
        if let t = lastSet[id], CACurrentMediaTime() - t < 0.5 { return }
        guard drag == nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        settleItems[id]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.settleItems[id] = nil
            self?.settle(id)
        }
        settleItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func trackerFocusChanged(pid: pid_t) {
        guard started, drag == nil, let id = tracker.focusedWindow(of: pid) else {
            syncStrips()
            return
        }
        // Cmd-Tab, the Dock or the app itself chose a hidden tab: show it.
        if tabs.isHidden(id), !minimized.contains(id), CACurrentMediaTime() > showingUntil {
            show(id, focus: false)
        } else {
            syncStrips()
        }
    }

    func trackerAppHidden(pid: pid_t, _ hidden: Bool) {
        syncStrips()
    }

    func trackerTitleChanged(_ id: WindowID) {
        guard tabs.allWindows.contains(id) else { return }
        strips[id]?.stripView.needsDisplay = true
    }
}

// MARK: - Mouse

extension TabManager: EventTapHandler {
    func mouseDown(at cgPoint: CGPoint, clickCount: Int, flags: CGEventFlags) -> Bool {
        guard started else { return false }
        drag = nil
        // A click may have raised a group's window above its strip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.syncStrips() }
        // The window server's bounds avoid a blocking AX call inside the tap. A press on a
        // strip belongs to the strip. A press on something above windows (a menu, the Dock)
        // starts a session for the window below that never moves, which does nothing.
        if let top = WindowList.frontmostOrdinary(at: cgPoint), top.pid != getpid(), tracker.windows[top.id] != nil {
            drag = DragSession(window: top.id, startFrame: Rect(top.bounds), followsStrip: tabs.group(containing: top.id)?.active == top.id)
        }
        return false
    }

    func mouseDragged(to cgPoint: CGPoint, flags: CGEventFlags) -> Bool {
        let now = CACurrentMediaTime()
        guard var session = drag, now - session.lastCheck > 0.016 else { return false }
        session.lastCheck = now
        let bounds = WindowList.bounds(of: session.window).map(Rect.init)
        if !session.moving, let frame = bounds, FrameChange(from: session.startFrame, to: frame) == .moved {
            session.moving = true
        }
        drag = session
        // The window server's position is ahead of the app's move notifications: follow it
        // for a strip that keeps up with the window.
        if session.followsStrip, let frame = bounds {
            let id = session.window
            DispatchQueue.main.async { self.followStrip(of: id, frame: frame) }
        }
        if session.moving {
            let point = Point(cgPoint)
            DispatchQueue.main.async { self.updateHover(session, at: point) }
        }
        return false
    }

    func mouseUp(at cgPoint: CGPoint, flags: CGEventFlags) -> Bool {
        guard let session = drag else { return false }
        drag = nil
        let point = Point(cgPoint)
        // Give the window server a moment to deliver the window's final position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let frame = self.tracker.windows[session.window]?.frame,
                  FrameChange(from: session.startFrame, to: frame) != .none || self.hover != nil
            else { return }
            self.finishDrag(session, at: point)
        }
        return false
    }
}
#endif
