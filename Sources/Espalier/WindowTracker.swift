#if os(macOS)
import AppKit
import ApplicationServices
import EspalierCore

/// A standard window of a regular app that Espalier can manage.
final class TrackedWindow {
    let id: WindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    var title: String
    /// Windows that can't be resized are never docked.
    let resizable: Bool

    init(id: WindowID, element: AXUIElement, pid: pid_t, bundleID: String, title: String, resizable: Bool) {
        self.id = id
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.resizable = resizable
    }

    var info: WindowInfo { WindowInfo(bundleID: bundleID, title: title) }
    var frame: Rect? { element.frame.map(Rect.init) }
    var isMinimized: Bool { element.bool(kAXMinimizedAttribute) ?? false }
}

protocol WindowTrackerDelegate: AnyObject {
    func trackerAdded(_ window: TrackedWindow)
    func trackerRemoved(_ id: WindowID)
    func trackerMinimized(_ id: WindowID, _ minimized: Bool)
    func trackerFrameChanged(_ id: WindowID)
    func trackerFocusChanged(pid: pid_t)
    func trackerAppHidden(pid: pid_t, _ hidden: Bool)
    func trackerTitleChanged(_ id: WindowID)
}

private final class AppObservation {
    let app: NSRunningApplication
    let element: AXUIElement
    let observer: AXObserver

    init(app: NSRunningApplication, element: AXUIElement, observer: AXObserver) {
        self.app = app
        self.element = element
        self.observer = observer
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handle(notification as String, element: element)
}

/// Discovers windows and relays their changes, using one AXObserver per app plus a
/// periodic reconcile for apps that don't post every notification.
final class WindowTracker: NSObject {
    weak var delegate: WindowTrackerDelegate?
    var excludedBundleIDs: Set<String> = []
    private(set) var windows: [WindowID: TrackedWindow] = [:]
    private var apps: [pid_t: AppObservation] = [:]
    private var timer: Timer?

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXTitleChangedNotification,
    ]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reconcile() }
    }

    func stop() {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for observation in apps.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .defaultMode)
        }
        apps.removeAll()
    }

    func focusedWindow(of pid: pid_t) -> WindowID? {
        guard let app = apps[pid] else { return nil }
        return app.element.element(kAXFocusedWindowAttribute)?.windowID
    }

    var frontmostWindow: WindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return focusedWindow(of: pid)
    }

    /// Re-scans every app: picks up windows whose creation was missed and drops ones that vanished.
    func reconcile() {
        for app in NSWorkspace.shared.runningApplications where apps[app.processIdentifier] == nil {
            observe(app)
        }
        let onScreen = WindowList.onScreenIDs()
        var seen = Set<WindowID>()
        for (pid, observation) in apps {
            for element in observation.element.elements(kAXWindowsAttribute) {
                guard let id = element.windowID else { continue }
                seen.insert(id)
                if windows[id] == nil, onScreen.contains(id) || (element.bool(kAXMinimizedAttribute) ?? false) {
                    consider(element, pid: pid)
                }
            }
        }
        // AX only lists windows on the current Space, so a window it no longer lists may just
        // be on another one. It's gone only once the window server no longer has it either.
        let missing = windows.keys.filter { !seen.contains($0) && !onScreen.contains($0) }
        guard !missing.isEmpty else { return }
        let existing = WindowList.allIDs()
        for id in missing where !existing.contains(id) {
            logger.debug("Window \(id) no longer exists")
            remove(id)
        }
    }

    // MARK: Apps

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Give the app a moment to finish launching before observing it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.observe(app) }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        for (id, w) in windows where w.pid == pid { remove(id) }
        if let observation = apps.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .defaultMode)
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        delegate?.trackerFocusChanged(pid: app.processIdentifier)
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard apps[pid] == nil, pid != getpid(), app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier, !excludedBundleIDs.contains(bundleID)
        else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // An app that's still launching refuses observers; the next reconcile retries it.
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon) == .success else {
            logger.debug("\(bundleID, privacy: .public) can't be observed yet")
            return
        }
        for name in WindowTracker.appNotifications where name != kAXWindowCreatedNotification {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        apps[pid] = AppObservation(app: app, element: element, observer: observer)
        let onScreen = WindowList.onScreenIDs()
        for window in element.elements(kAXWindowsAttribute) {
            if let id = window.windowID, onScreen.contains(id) || (window.bool(kAXMinimizedAttribute) ?? false) {
                consider(window, pid: pid)
            }
        }
    }

    // MARK: Windows

    private func consider(_ element: AXUIElement, pid: pid_t) {
        guard let observation = apps[pid], let id = element.windowID, windows[id] == nil,
              element.string(kAXRoleAttribute) == kAXWindowRole,
              element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              element.bool("AXFullScreen") != true,
              let bundleID = observation.app.bundleIdentifier
        else { return }
        let window = TrackedWindow(
            id: id, element: element, pid: pid, bundleID: bundleID,
            title: element.string(kAXTitleAttribute) ?? "",
            resizable: element.isSettable(kAXSizeAttribute)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in WindowTracker.windowNotifications {
            AXObserverAddNotification(observation.observer, element, name as CFString, refcon)
        }
        windows[id] = window
        logger.debug("Tracking window \(id) of \(bundleID, privacy: .public)")
        delegate?.trackerAdded(window)
    }

    private func remove(_ id: WindowID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        if let observation = apps[window.pid] {
            for name in WindowTracker.windowNotifications {
                AXObserverRemoveNotification(observation.observer, window.element, name as CFString)
            }
        }
        delegate?.trackerRemoved(id)
    }

    private func id(of element: AXUIElement) -> WindowID? {
        if let id = element.windowID, windows[id] != nil { return id }
        return windows.values.first { CFEqual($0.element, element) }?.id
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let pid = element.pid {
                consider(element, pid: pid)
                // Some apps finish configuring a new window (subrole, size) just after announcing it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.consider(element, pid: pid) }
            }
        case kAXUIElementDestroyedNotification:
            if let id = id(of: element) { remove(id) }
        case kAXWindowMiniaturizedNotification:
            if let id = id(of: element) { delegate?.trackerMinimized(id, true) }
        case kAXWindowDeminiaturizedNotification:
            if let id = id(of: element) { delegate?.trackerMinimized(id, false) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let id = id(of: element) { delegate?.trackerFrameChanged(id) }
        case kAXTitleChangedNotification:
            if let id = id(of: element) {
                windows[id]?.title = element.string(kAXTitleAttribute) ?? ""
                delegate?.trackerTitleChanged(id)
            }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if let pid = element.pid { delegate?.trackerFocusChanged(pid: pid) }
        case kAXApplicationHiddenNotification:
            if let pid = element.pid { delegate?.trackerAppHidden(pid: pid, true) }
        case kAXApplicationShownNotification:
            if let pid = element.pid { delegate?.trackerAppHidden(pid: pid, false) }
        default:
            break
        }
    }
}
#endif
