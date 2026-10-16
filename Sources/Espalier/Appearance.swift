#if os(macOS)
import AppKit
import EspalierCore
import ScreenCaptureKit

/// App icons and their dominant colours, used to draw windows that can't be shown.
final class AppearanceCache {
    private var colors: [String: NSColor] = [:]
    private var icons: [pid_t: NSImage] = [:]

    func icon(pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    func color(bundleID: String, pid: pid_t) -> NSColor {
        if let cached = colors[bundleID] { return cached }
        let color = icon(pid: pid).map(AppearanceCache.dominantColor) ?? NSColor.systemGray
        colors[bundleID] = color
        return color
    }

    /// The icon's alpha-weighted average colour, nudged to a readable saturation and brightness.
    private static func dominantColor(of image: NSImage) -> NSColor {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return .systemGray }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let a = Double(c.alphaComponent)
                r += Double(c.redComponent) * a
                g += Double(c.greenComponent) * a
                b += Double(c.blueComponent) * a
                total += a
            }
        }
        guard total > 0 else { return .systemGray }
        let average = NSColor(deviceRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            deviceHue: hue,
            saturation: min(1, saturation * 1.25 + 0.08),
            brightness: min(max(brightness, 0.38), 0.72),
            alpha: 1
        )
    }
}

/// Window snapshots for drawing windows in motion. Needs the optional Screen Recording
/// permission; without it, windows are drawn as their app's colour and icon.
final class Snapshotter: @unchecked Sendable {
    private(set) var images: [WindowID: CGImage] = [:]

    var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    func requestAccess() {
        CGRequestScreenCaptureAccess()
    }

    func forget(_ id: WindowID) {
        images[id] = nil
    }

    /// Captures `ids`, then calls `completion` on the main queue, after `timeout` at the latest.
    func capture(_ ids: [WindowID], timeout: TimeInterval, completion: @escaping () -> Void) {
        guard isAuthorized, !ids.isEmpty else {
            completion()
            return
        }
        let once = Once(completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once.fire() }
        let wanted = Set(ids)
        Task.detached {
            let captured = await Snapshotter.captureImages(wanted)
            DispatchQueue.main.async {
                for (id, image) in captured { self.images[id] = image }
                once.fire()
            }
        }
    }

    private static func captureImages(_ ids: Set<WindowID>) async -> [WindowID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [:] }
        var result: [WindowID: CGImage] = [:]
        for window in content.windows where ids.contains(window.windowID) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            // Point size (half the pixels on Retina) is plenty for a moving proxy.
            configuration.width = max(1, Int(window.frame.width))
            configuration.height = max(1, Int(window.frame.height))
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                result[window.windowID] = image
            }
        }
        return result
    }
}
#endif
