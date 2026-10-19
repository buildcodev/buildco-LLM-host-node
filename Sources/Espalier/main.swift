#if os(macOS)
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// A plain `kill` (as the installer sends before replacing the app) quits the normal way,
// so hidden tabs are put back on screen first.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { app.terminate(nil) }
terminationSource.resume()

app.run()
#else
import Foundation

FileHandle.standardError.write("Espalier is a macOS window manager. Only the EspalierCore library builds on this platform.\n".data(using: .utf8)!)
exit(1)
#endif
