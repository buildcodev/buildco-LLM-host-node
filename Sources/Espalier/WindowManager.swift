#if os(macOS)
import AppKit
import EspalierCore

private struct DragSession {
    enum Mode { case pending, moving, resizing }
    let window: WindowID
    let startFrame: Rect
    let sourceDisplay: String
    var mode: Mode = .pending
    var lastCheck: CFTimeInterval = 0
}

private struct DividerSession {
    let display: String
    let divider: Divider
}

private struct PinchState {
    var active: Bool
    var accumulated: Double
    var lastEvent: CFTimeInterval
}

/// Connects the layout engine to real windows: keeps one `DisplayState` per display,
/// turns its presentation into AX frame changes and overlay drawing, and routes input.
final class WindowManager: NSObject {
    private(set) var config = Config()
    private(set) var problems: [String] = []
    private(set) var started = false
    var onChange: (() -> Void)?

    private let store: StateStore
    private let tracker = WindowTracker()
    private let eventTap = EventTap()
    private let hotkeys = HotkeyCenter()
    private let appearance = AppearanceCache()
    let snapshotter = Snapshotter()

    private var displays: [Display] = []
    private var states: [String: DisplayState] = [:]
    /// States of displays that are disconnected, kept for when they come back.
    private var dormant: [String: DisplayState] = [:]
    private var presentations: [String: Presentation] = [:]
    private var overlays: [String: OverlayController] = [:]

    private var restoring = false
    private var parked: Set<WindowID> = []
    private var minimized: Set<WindowID> = []
    private var hiddenApps: Set<pid_t> = []
    private var offSpace: Set<WindowID> = []
    private var minSizes: [WindowID: Size] = [:]
    private var lastSet: [WindowID: CFTimeInterval] = [:]
    private var seenAt: [WindowID: CFTimeInterval] = [:]

    private var drag: DragSession?
    private var dividerDrag: DividerSession?
    private var lastDividerApply: CFTimeInterval = 0
    private var pinch: PinchState?
    private var saveItem: DispatchWorkItem?
    private var reapplyItems: [String: DispatchWorkItem] = [:]
    private var presenceTimer: Timer?

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
        // A hung app must not stall Espalier (and with it the event tap). Setting the timeout
        // on the system-wide element changes the default for every element.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        tracker.delegate = self
        eventTap.handler = self
        if !eventTap.start() { problems.append("Couldn't watch the mouse: docking and gap resizing are off") }
        hotkeys.onCommand = { [weak self] command in self?.perform(command) }
        registerHotkeys()
        displays = Displays.all()
        rebuildOverlays()

        restoring = true
        tracker.start()
        restore()
        restoring = false

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPresence() }
        logger.info("Started with \(self.displays.count) display(s) and \(self.tracker.windows.count) window(s)")
        onChange?()
    }

    /// Saves, then puts every parked window back on screen so nothing is lost when Espalier quits.
    func stop() {
        guard started else { return }
        saveNow()
        for id in parked {
            guard let w = tracker.windows[id], let uuid = displayUUID(of: id), let display = findDisplay(uuid) else { continue }
            let size = w.element.size ?? CGSize(width: 800, height: 600)
            let fallback = Rect(
                x: display.visibleFrame.midX - Double(size.width) / 2, y: display.visibleFrame.midY - Double(size.height) / 2,
                width: Double(size.width), height: Double(size.height)
            )
            let target = (states[uuid]?.floating[id] ?? fallback).clamped(into: display.visibleFrame)
            w.element.setFrame(target.cgRect)
        }
        parked.removeAll()
        eventTap.stop()
        hotkeys.unregisterAll()
        tracker.stop()
        presenceTimer?.invalidate()
        overlays.values.forEach { $0.close() }
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
        presentations.removeAll()
        applyAll(animated: false)
    }

    /// The shortcut for each command, for menus.
    var shortcuts: [Command: Hotkey] {
        var result: [Command: Hotkey] = [:]
        for (hotkey, command) in config.bindings().bindings { result[command] = hotkey }
        return result
    }

    /// Saved view slots on the display that has focus.
    var savedViews: Set<Int> {
        guard let uuid = activeDisplayUUID(), let state = states[uuid] else { return [] }
        return Set(state.navigation.saved.keys.compactMap(Int.init))
    }

    func resetActiveDisplay() {
        guard let uuid = activeDisplayUUID(), var state = states[uuid] else { return }
        for id in state.layout.allWindows {
            if let frame = tracker.windows[id]?.frame { state.floating[id] = frame }
        }
        state.layout = Layout()
        state.navigation = Navigation()
        states[uuid] = state
        apply(uuid, animated: false)
        scheduleSave()
    }

    private func registerHotkeys() {
        let (bindings, bindingProblems) = config.bindings()
        let registrationProblems = hotkeys.register(bindings)
        problems = Array(Set(problems + bindingProblems + registrationProblems)).sorted()
        for problem in problems { logger.warning("\(problem, privacy: .public)") }
    }

    private func restore() {
        let snapshot = store.loadSnapshot()
        var live = tracker.windows.mapValues(\.info)
        for app in NSWorkspace.shared.runningApplications where app.isHidden { hiddenApps.insert(app.processIdentifier) }
        for window in tracker.windows.values where window.isMinimized { minimized.insert(window.id) }
        let now = CACurrentMediaTime()
        for id in tracker.windows.keys { seenAt[id] = now }

        if let snapshot {
            for (uuid, state) in snapshot.displays where !displays.contains(where: { $0.uuid == uuid }) {
                dormant[uuid] = state
            }
        }
        for display in displays {
            var state = snapshot?.displays[display.uuid] ?? DisplayState()
            let mapping = WindowMatcher.match(saved: state.windowInfo, live: live)
            state.remap(mapping)
            for id in mapping.values {
                live[id] = nil
                state.windowInfo[id] = tracker.windows[id]?.info
                // Floating windows are only moved when parked, so one stranded by a crash
                // goes back to where it last floated.
                if let remembered = state.floating[id], let w = tracker.windows[id], let frame = w.frame {
                    state.floating[id] = rescueIfStranded(w, frame: frame, on: display, preferring: remembered)
                }
            }
            states[display.uuid] = state
        }
        // Every other window floats where it is.
        for id in live.keys.sorted() {
            guard let w = tracker.windows[id], let frame = w.frame, let display = displays.best(for: frame) else { continue }
            states[display.uuid]?.floating[id] = rescueIfStranded(w, frame: frame, on: display)
            states[display.uuid]?.windowInfo[id] = w.info
        }
        refreshPresence(apply: false)
        applyAll(animated: false)
        scheduleSave()
    }

    // MARK: Lookup

    private func findDisplay(_ uuid: String) -> Display? {
        displays.first { $0.uuid == uuid }
    }

    private func displayUUID(of id: WindowID) -> String? {
        states.first { $0.value.manages(id) }?.key
    }

    private var mouseLocation: Point? {
        CGEvent(source: nil).map { Point($0.location) }
    }

    private func activeDisplayUUID() -> String? {
        if let focused = tracker.frontmostWindow, let uuid = displayUUID(of: focused) { return uuid }
        if let mouse = mouseLocation, let display = displays.containing(mouse) { return display.uuid }
        return displays.first?.uuid
    }

    private func isAway(_ id: WindowID) -> Bool {
        guard let w = tracker.windows[id] else { return true }
        return minimized.contains(id) || hiddenApps.contains(w.pid) || offSpace.contains(id)
    }

    private func look(_ id: WindowID) -> WindowLook? {
        guard let w = tracker.windows[id] else { return nil }
        return WindowLook(
            color: appearance.color(bundleID: w.bundleID, pid: w.pid),
            icon: appearance.icon(pid: w.pid),
            title: w.title,
            snapshot: snapshotter.images[id].map { NSImage(cgImage: $0, size: .zero) }
        )
    }

    // MARK: Applying layouts

    private func rebuildOverlays() {
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        for display in displays {
            overlays[display.uuid] = OverlayController(display: display) { [weak self] id in self?.look(id) }
        }
    }

    private func applyAll(animated: Bool) {
        for display in displays { apply(display.uuid, animated: animated) }
    }

    private func scheduleReapply(_ uuid: String?) {
        guard let uuid else { return }
        reapplyItems[uuid]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.apply(uuid, animated: false) }
        reapplyItems[uuid] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Puts a display's windows where its layout says, animating camera moves.
    private func apply(_ uuid: String, animated: Bool) {
        guard let display = findDisplay(uuid), let state = states[uuid] else { return }
        let previous = presentations[uuid]
        let new = state.presentation(screen: display.visibleFrame, metrics: config.metrics, minSizes: minSizes)
        presentations[uuid] = new
        defer { onChange?() }

        let cameraMoved = previous.map { $0.target != new.target || !$0.camera.isApproximatelyEqual(to: new.camera, tolerance: 1e-6) } ?? false
        guard animated, cameraMoved, config.animationDuration > 0, let old = previous, let overlay = overlays[uuid] else {
            place(new, state: state, display: display)
            overlays[uuid]?.update(tiles: new.tiles, strips: new.tabStrips)
            return
        }
        // Snapshot what's visible now, cover the screen with moving proxies, and move the
        // real windows underneath while the overlay hides the jump.
        let visibleNow = Array(old.windowFrames.keys) + state.floating.keys.filter { !parked.contains($0) && !isAway($0) }
        snapshotter.capture(visibleNow, timeout: 0.15) { [weak self] in
            guard let self, let latestState = self.states[uuid], let latest = self.presentations[uuid] else { return }
            let proxies = self.proxies(from: old, to: latest, state: latestState, display: display)
            overlay.animate(proxies, useSnapshots: self.snapshotter.isAuthorized, duration: self.config.animationDuration) {}
            self.place(latest, state: latestState, display: display)
            overlay.update(tiles: latest.tiles, strips: latest.tabStrips)
        }
    }

    private func place(_ p: Presentation, state: DisplayState, display: Display) {
        for (id, frame) in p.windowFrames where !isAway(id) { setFrame(id, frame) }
        for id in p.parked where !isAway(id) { park(id, on: display) }
        for (id, remembered) in state.floating where !isAway(id) {
            if let desktop = p.desktopRect {
                if parked.contains(id) { setFrame(id, remembered.clamped(into: desktop)) }
            } else {
                park(id, on: display)
            }
        }
    }

    private func setFrame(_ id: WindowID, _ frame: Rect) {
        guard let w = tracker.windows[id] else { return }
        let wasParked = parked.remove(id) != nil
        if !wasParked, let current = w.frame, current.isApproximatelyEqual(to: frame, tolerance: 1) { return }
        lastSet[id] = CACurrentMediaTime()
        withoutEnhancedUserInterface(pid: w.pid) { w.element.setFrame(frame.cgRect) }
        // A window that refuses to shrink tells us its minimum size; it's drawn as a tile
        // wherever its slot is smaller than that, instead of overlapping its neighbours.
        guard let actual = w.element.size else { return }
        let tooWide = Double(actual.width) > frame.width + 4
        let tooTall = Double(actual.height) > frame.height + 4
        if tooWide || tooTall {
            let known = minSizes[id] ?? .zero
            minSizes[id] = Size(
                width: tooWide ? max(known.width, Double(actual.width)) : known.width,
                height: tooTall ? max(known.height, Double(actual.height)) : known.height
            )
            scheduleReapply(displayUUID(of: id))
        }
    }

    private func park(_ id: WindowID, on display: Display) {
        guard let w = tracker.windows[id] else { return }
        let size = w.element.size ?? CGSize(width: 800, height: 600)
        let origin = display.parkingOrigin(for: size, among: displays)
        if parked.contains(id), let position = w.element.position, abs(position.x - origin.x) < 2, abs(position.y - origin.y) < 2 { return }
        lastSet[id] = CACurrentMediaTime()
        w.element.setPosition(origin)
        parked.insert(id)
    }

    /// A window that arrives almost entirely off screen, like one parked when Espalier
    /// crashed or was force quit, is moved back into view so it can't be lost.
    private func rescueIfStranded(_ w: TrackedWindow, frame: Rect, on display: Display, preferring remembered: Rect? = nil) -> Rect {
        let visible = frame.intersection(display.visibleFrame)
        guard visible.width < 40 || visible.height < 40 else { return frame }
        let rescued = (remembered ?? frame).clamped(into: display.visibleFrame)
        logger.info("Bringing stranded window \(w.id) back on screen at \(rescued, privacy: .public)")
        lastSet[w.id] = CACurrentMediaTime()
        withoutEnhancedUserInterface(pid: w.pid) { w.element.setFrame(rescued.cgRect) }
        return rescued
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

    private func proxies(from old: Presentation, to new: Presentation, state: DisplayState, display: Display) -> [Proxy] {
        var result: [Proxy] = []
        func onScreen(_ r: Rect) -> Bool { r.overlaps(display.frame) }

        let desktop = state.layout.desktopID
        if let a = old.nodeRects[desktop], let b = new.nodeRects[desktop], onScreen(a) || onScreen(b) {
            result.append(Proxy(kind: .desktop, from: display.local(a), to: display.local(b), look: nil))
            // Floating windows ride along with the desktop.
            for (id, remembered) in state.floating.sorted(by: { $0.key < $1.key }) where !isAway(id) {
                let from = old.desktopRect != nil ? remembered : remembered.mapped(from: b, to: a)
                let to = new.desktopRect.map { remembered.clamped(into: $0) } ?? remembered.mapped(from: a, to: b)
                guard onScreen(from) || onScreen(to) else { continue }
                result.append(Proxy(kind: .window, from: display.local(from), to: display.local(to), look: look(id)))
            }
        }
        for node in state.layout.root.allNodes {
            guard case .group(let g) = node, let active = g.activeWindow, let b = new.nodeRects[g.id] else { continue }
            let a = old.nodeRects[g.id] ?? b
            guard onScreen(a) || onScreen(b) else { continue }
            result.append(Proxy(kind: .window, from: display.local(a), to: display.local(b), look: look(active)))
        }
        return result
    }

    private func hidePreviews() {
        overlays.values.forEach { $0.showPreview(nil) }
    }

    // MARK: Presence (minimized, hidden, other Spaces)

    private func refreshPresence(apply shouldApply: Bool = true) {
        let onScreen = WindowList.onScreenIDs()
        let now = CACurrentMediaTime()
        offSpace = Set(tracker.windows.values.filter { w in
            // Windows we parked are still on this Space; brand-new ones may not be listed yet.
            !onScreen.contains(w.id) && !parked.contains(w.id) && !minimized.contains(w.id)
                && !hiddenApps.contains(w.pid) && now - (seenAt[w.id] ?? 0) > 2
        }.map(\.id))
        for (uuid, var state) in states {
            var changed = false
            for node in state.layout.root.allNodes {
                guard case .group(let g) = node else { continue }
                for slot in g.slots where slot.suspended != isAway(slot.window) {
                    logger.debug("Window \(slot.window) is \(self.isAway(slot.window) ? "away" : "back", privacy: .public)")
                    state.setSuspended(slot.window, isAway(slot.window))
                    changed = true
                }
            }
            guard changed else { continue }
            states[uuid] = state
            if shouldApply { apply(uuid, animated: false) }
        }
    }

    @objc private func spaceChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshPresence() }
    }

    @objc private func screensChanged() {
        let current = Displays.all()
        guard current != displays else { return }
        let removed = displays.filter { old in !current.contains { $0.uuid == old.uuid } }
        displays = current
        for display in removed {
            guard let state = states.removeValue(forKey: display.uuid) else { continue }
            dormant[display.uuid] = state
            // macOS moves the windows of a disconnected display; they float wherever they land.
            for id in state.managedWindows {
                guard let w = tracker.windows[id], let frame = w.frame, let target = displays.best(for: frame) else { continue }
                parked.remove(id)
                states[target.uuid]?.floating[id] = frame
                states[target.uuid]?.windowInfo[id] = w.info
            }
        }
        for display in current where states[display.uuid] == nil {
            var state = dormant.removeValue(forKey: display.uuid) ?? DisplayState()
            // Reclaim this display's windows from wherever they floated meanwhile.
            let live = state.managedWindows.filter { tracker.windows[$0] != nil }
            for id in live {
                for uuid in states.keys where states[uuid]?.manages(id) == true { states[uuid]?.forget(id) }
            }
            var mapping: [WindowID: WindowID] = [:]
            for id in live { mapping[id] = id }
            state.remap(mapping)
            states[display.uuid] = state
        }
        rebuildOverlays()
        presentations.removeAll()
        applyAll(animated: false)
        scheduleSave()
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
        for uuid in Array(states.keys) {
            for id in states[uuid]?.managedWindows ?? [] {
                if let w = tracker.windows[id] { states[uuid]?.windowInfo[id] = w.info }
            }
        }
        var all = dormant
        for (uuid, state) in states { all[uuid] = state }
        store.save(WorkspaceSnapshot(displays: all))
    }

    // MARK: Commands

    func perform(_ command: Command) {
        guard started else {
            logger.info("Ignoring \(command.name, privacy: .public): not running yet")
            return
        }
        let focused = tracker.frontmostWindow
        guard let uuid = activeDisplayUUID(), var state = states[uuid], let display = findDisplay(uuid) else { return }
        let screen = display.visibleFrame
        let metrics = config.metrics
        var animated = true

        switch command {
        case .arrange:
            let eligible = Set(state.floating.keys.filter { !isAway($0) && tracker.windows[$0]?.resizable == true })
            logger.info("Arranging \(eligible.count) floating window(s) on \(uuid, privacy: .public)")
            state.arrange(screen: screen, metrics: metrics, only: eligible)
        case .relayout:
            for id in state.managedWindows { minSizes[id] = nil }
            presentations[uuid] = nil
            animated = false
        case .back:
            state.back()
        case .forward:
            state.forward()
        case .zoomOut:
            state.zoomOut()
        case .zoomIn:
            var toward = mouseLocation.flatMap { screen.contains($0) ? $0 : nil }
            if toward == nil, let focused, let frame = tracker.windows[focused]?.frame { toward = frame.center }
            state.zoomIn(toward: toward, screen: screen, metrics: metrics)
        case .overview:
            state.toggleOverview()
        case .maximize:
            if let focused, state.isDocked(focused) { state.toggleMaximize(focused) }
        case .toggleFloat:
            guard let focused, let w = tracker.windows[focused], let frame = w.frame, w.resizable || state.isDocked(focused) else { return }
            state.toggleFloat(focused, currentFrame: frame, screen: screen, metrics: metrics)
        case .focus(let edge):
            guard let focused, let p = presentations[uuid], let next = state.neighbour(of: focused, toward: edge, presentation: p) else { return }
            focus(next)
            return
        case .dock(let edge):
            guard let focused, let w = tracker.windows[focused], w.resizable, let frame = w.frame else { return }
            state.applyDrop(.dock(state.target, edge), window: focused, frame: frame, screen: screen, metrics: metrics)
        case .view(let slot):
            state.recallView(slot)
        case .saveView(let slot):
            state.saveView(slot)
            animated = false
        case .nextTab, .previousTab:
            guard let focused, let g = state.layout.group(containing: focused) else { return }
            let tabs = g.presentWindows
            guard tabs.count > 1, let i = tabs.firstIndex(of: g.activeWindow ?? focused) else { return }
            let next = tabs[(i + (command == .nextTab ? 1 : tabs.count - 1)) % tabs.count]
            state.layout.activate(next)
            states[uuid] = state
            apply(uuid, animated: false)
            focus(next)
            scheduleSave()
            return
        }
        states[uuid] = state
        apply(uuid, animated: animated)
        scheduleSave()
    }

    private func focus(_ id: WindowID) {
        guard let w = tracker.windows[id] else { return }
        AXUIElementCreateApplication(w.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
        w.element.set(kAXMainAttribute, kCFBooleanTrue)
        w.element.raise()
    }

    private func zoom(in zoomIn: Bool, toward point: Point) {
        guard let display = displays.containing(point), var state = states[display.uuid] else { return }
        if zoomIn {
            state.zoomIn(toward: point, screen: display.visibleFrame, metrics: config.metrics)
        } else {
            state.zoomOut()
        }
        states[display.uuid] = state
        apply(display.uuid, animated: true)
        scheduleSave()
    }

    // MARK: Drags

    private func updatePreview(for session: DragSession, at point: Point, flags: CGEventFlags) {
        guard config.docking, !flags.contains(modifierNamed: config.keepFloatingModifier),
              let w = tracker.windows[session.window], w.resizable,
              let display = displays.containing(point), let p = presentations[display.uuid], var state = states[display.uuid]
        else {
            hidePreviews()
            return
        }
        if display.uuid != session.sourceDisplay { state.forget(session.window) }
        let action = state.dropAction(for: session.window, at: point, presentation: p, metrics: config.metrics)
        let preview = state.previewFrame(
            for: action, window: session.window, frame: w.frame ?? session.startFrame,
            screen: display.visibleFrame, metrics: config.metrics, minSizes: minSizes
        )
        for (uuid, overlay) in overlays { overlay.showPreview(uuid == display.uuid ? preview : nil) }
    }

    private func finishDrag(_ session: DragSession, at point: Point, flags: CGEventFlags) {
        guard let w = tracker.windows[session.window], let frame = w.frame else { return }
        let metrics = config.metrics
        var mode = session.mode
        if mode == .pending {
            // A quick drag can end before the window server reports the window moving.
            switch FrameChange(from: session.startFrame, to: frame) {
            case .none: return
            case .moved: mode = .moving
            case .resized: mode = .resizing
            }
        }
        logger.debug("Drag of \(w.id) ended: \(String(describing: mode), privacy: .public) from \(session.startFrame, privacy: .public) to \(frame, privacy: .public)")
        switch mode {
        case .pending:
            return
        case .resizing:
            guard var state = states[session.sourceDisplay] else { return }
            if state.isDocked(w.id), let p = presentations[session.sourceDisplay] {
                state.resizeDocked(w.id, from: session.startFrame, to: frame, presentation: p, metrics: metrics)
                minSizes[w.id] = nil
            } else {
                state.noteFloatingFrame(w.id, frame)
            }
            states[session.sourceDisplay] = state
            apply(session.sourceDisplay, animated: false)
        case .moving:
            guard let target = displays.containing(point) ?? findDisplay(session.sourceDisplay), var state = states[target.uuid] else { return }
            let crossing = target.uuid != session.sourceDisplay
            if crossing {
                states[session.sourceDisplay]?.forget(w.id)
                state.windowInfo[w.id] = w.info
            }
            let keepFloating = flags.contains(modifierNamed: config.keepFloatingModifier) || !config.docking || !w.resizable
            var action = DropAction.float
            if !keepFloating, let p = presentations[target.uuid] {
                action = state.dropAction(for: w.id, at: point, presentation: p, metrics: metrics)
            }
            if crossing, action == .none { action = .float }
            logger.info("Dropped \(w.id) at \(point.x, privacy: .public),\(point.y, privacy: .public): \(String(describing: action), privacy: .public)")
            state.applyDrop(action, window: w.id, frame: frame, screen: target.visibleFrame, metrics: metrics)
            if state.windowInfo[w.id] == nil { state.windowInfo[w.id] = w.info }
            states[target.uuid] = state
            if crossing { apply(session.sourceDisplay, animated: false) }
            apply(target.uuid, animated: true)
        }
        scheduleSave()
    }
}

// MARK: - Window events

extension WindowManager: WindowTrackerDelegate {
    func trackerAdded(_ window: TrackedWindow) {
        seenAt[window.id] = CACurrentMediaTime()
        guard started, !restoring else { return }
        if window.isMinimized { minimized.insert(window.id) }
        guard displayUUID(of: window.id) == nil, let frame = window.frame, let display = displays.best(for: frame) else { return }
        let rescued = rescueIfStranded(window, frame: frame, on: display)
        states[display.uuid]?.adoptFloating(window.id, frame: rescued, info: window.info)
        // Make sure the desktop it opened on is big enough to show it.
        states[display.uuid]?.reveal(window.id, screen: display.visibleFrame, metrics: config.metrics, minSizes: minSizes)
        apply(display.uuid, animated: true)
        scheduleSave()
    }

    func trackerRemoved(_ id: WindowID) {
        for uuid in Array(states.keys) where states[uuid]?.manages(id) == true {
            states[uuid]?.forget(id)
            apply(uuid, animated: false)
        }
        parked.remove(id)
        minimized.remove(id)
        offSpace.remove(id)
        minSizes[id] = nil
        lastSet[id] = nil
        seenAt[id] = nil
        snapshotter.forget(id)
        if drag?.window == id {
            drag = nil
            hidePreviews()
        }
        scheduleSave()
    }

    func trackerMinimized(_ id: WindowID, _ isMinimized: Bool) {
        if isMinimized { minimized.insert(id) } else { minimized.remove(id) }
        guard let uuid = displayUUID(of: id), let display = findDisplay(uuid) else { return }
        states[uuid]?.setSuspended(id, isAway(id))
        if !isMinimized {
            // It comes back to its slot; make sure that slot is on screen.
            parked.remove(id)
            states[uuid]?.reveal(id, screen: display.visibleFrame, metrics: config.metrics, minSizes: minSizes)
        }
        apply(uuid, animated: !isMinimized)
        scheduleSave()
    }

    func trackerFrameChanged(_ id: WindowID) {
        guard started, drag == nil, dividerDrag == nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        if let t = lastSet[id], CACurrentMediaTime() - t < 0.8 { return }
        guard let uuid = displayUUID(of: id), let state = states[uuid] else { return }
        if state.isDocked(id) {
            // Something other than the user moved a docked window: put it back.
            scheduleReapply(uuid)
        } else if state.isFloating(id), !parked.contains(id), let w = tracker.windows[id], let frame = w.frame {
            if let display = displays.best(for: frame), display.uuid != uuid, states[display.uuid] != nil {
                // It reached another display some other way than a drag we followed (a quick
                // flick, a keyboard shortcut, the app itself): it floats there now.
                logger.info("Floating window \(id) moved to display \(display.uuid, privacy: .public)")
                states[uuid]?.forget(id)
                states[display.uuid]?.adoptFloating(id, frame: frame, info: w.info)
                apply(uuid, animated: false)
                apply(display.uuid, animated: true)
            } else {
                states[uuid]?.noteFloatingFrame(id, frame)
            }
            scheduleSave()
        }
    }

    func trackerFocusChanged(pid: pid_t) {
        guard started, drag == nil, let id = tracker.focusedWindow(of: pid), let uuid = displayUUID(of: id),
              let display = findDisplay(uuid), var state = states[uuid]
        else { return }
        var changed = false
        if let g = state.layout.group(containing: id), g.activeWindow != id, g.presentWindows.contains(id) {
            state.layout.activate(id)
            changed = true
        }
        let before = state.navigation.current
        state.reveal(id, screen: display.visibleFrame, metrics: config.metrics, minSizes: minSizes)
        changed = changed || state.navigation.current != before
        guard changed else { return }
        states[uuid] = state
        apply(uuid, animated: true)
        scheduleSave()
    }

    func trackerAppHidden(pid: pid_t, _ hidden: Bool) {
        if hidden { hiddenApps.insert(pid) } else { hiddenApps.remove(pid) }
        var affected = Set<String>()
        for w in tracker.windows.values where w.pid == pid {
            guard let uuid = displayUUID(of: w.id) else { continue }
            states[uuid]?.setSuspended(w.id, isAway(w.id))
            if !hidden { parked.remove(w.id) }
            affected.insert(uuid)
        }
        for uuid in affected { apply(uuid, animated: false) }
    }
}

// MARK: - Mouse and trackpad

extension WindowManager: EventTapHandler {
    func mouseDown(at cgPoint: CGPoint, clickCount: Int, flags: CGEventFlags) -> Bool {
        guard started else { return false }
        // A press always starts fresh, even if the tap missed the last release.
        drag = nil
        let point = Point(cgPoint)
        if let top = WindowList.frontmost(at: cgPoint, excludingPID: getpid()) {
            // A window (or the Dock, a menu…) is under the pointer. Watch a managed window in
            // case this press turns into a move or a resize. The window server's bounds avoid
            // a blocking AX call inside the tap.
            if top.layer == 0, tracker.windows[top.id] != nil, let uuid = displayUUID(of: top.id) {
                drag = DragSession(window: top.id, startFrame: Rect(top.bounds), sourceDisplay: uuid)
            }
            return false
        }
        // Bare desktop: gaps, tab strips and tiles are ours.
        guard let display = displays.containing(point), let p = presentations[display.uuid] else { return false }
        let uuid = display.uuid
        if let divider = p.divider(at: point) {
            dividerDrag = DividerSession(display: uuid, divider: divider)
            return true
        }
        if let strip = p.tabStrip(at: point), let tab = strip.tab(at: point) {
            DispatchQueue.main.async {
                self.states[uuid]?.layout.activate(tab)
                self.apply(uuid, animated: false)
                self.focus(tab)
                self.scheduleSave()
            }
            return true
        }
        if let tile = p.tile(at: point) {
            if clickCount >= 2 {
                DispatchQueue.main.async {
                    self.states[uuid]?.frame(tile.node)
                    self.apply(uuid, animated: true)
                    self.scheduleSave()
                }
            }
            return true
        }
        return false
    }

    func mouseDragged(to cgPoint: CGPoint, flags: CGEventFlags) -> Bool {
        let point = Point(cgPoint)
        let now = CACurrentMediaTime()
        if let session = dividerDrag {
            states[session.display]?.moveDivider(session.divider, to: point.coordinate(along: session.divider.axis), metrics: config.metrics)
            if now - lastDividerApply > 1.0 / 30 {
                lastDividerApply = now
                DispatchQueue.main.async { self.apply(session.display, animated: false) }
            }
            return true
        }
        guard var session = drag, now - session.lastCheck > 0.04 else { return false }
        session.lastCheck = now
        if session.mode == .pending, let frame = WindowList.bounds(of: session.window).map(Rect.init) {
            switch FrameChange(from: session.startFrame, to: frame) {
            case .none: break
            case .moved: session.mode = .moving
            case .resized: session.mode = .resizing
            }
        }
        drag = session
        if session.mode == .moving {
            let current = session
            DispatchQueue.main.async { self.updatePreview(for: current, at: point, flags: flags) }
        }
        return false
    }

    func mouseUp(at cgPoint: CGPoint, flags: CGEventFlags) -> Bool {
        if let session = dividerDrag {
            dividerDrag = nil
            DispatchQueue.main.async {
                self.apply(session.display, animated: false)
                self.scheduleSave()
            }
            return true
        }
        guard let session = drag else { return false }
        drag = nil
        let point = Point(cgPoint)
        // Give the window server a moment to deliver the window's final position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.hidePreviews()
            self.finishDrag(session, at: point, flags: flags)
        }
        return false
    }

    func magnify(by amount: Double, phase: NSEvent.Phase, at cgPoint: CGPoint, flags: CGEventFlags) -> Bool {
        guard started, config.gestures else { return false }
        let now = CACurrentMediaTime()
        if pinch == nil || phase.contains(.began) || now - (pinch?.lastEvent ?? 0) > 0.3 {
            // Option-pinch anywhere, or a plain pinch over bare wallpaper, zooms the layout.
            let overWallpaper = WindowList.frontmost(at: cgPoint, excludingPID: getpid()) == nil
            pinch = PinchState(active: flags.contains(modifierNamed: config.pinchModifier) || overWallpaper, accumulated: 0, lastEvent: now)
        }
        guard var state = pinch else { return false }
        state.lastEvent = now
        defer { pinch = (phase.contains(.ended) || phase.contains(.cancelled)) ? nil : state }
        guard state.active else { return false }
        state.accumulated += amount
        let point = Point(cgPoint)
        if state.accumulated >= config.pinchStep {
            state.accumulated = 0
            DispatchQueue.main.async { self.zoom(in: true, toward: point) }
        } else if state.accumulated <= -config.pinchStep {
            state.accumulated = 0
            DispatchQueue.main.async { self.zoom(in: false, toward: point) }
        }
        return true
    }
}
#endif
