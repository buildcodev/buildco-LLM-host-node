#if os(macOS)
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#else
import Foundation

FileHandle.standardError.write("Espalier is a macOS window manager. Only the EspalierCore library builds on this platform.\n".data(using: .utf8)!)
exit(1)
#endif
