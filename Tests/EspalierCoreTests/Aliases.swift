@testable import EspalierCore

// On macOS, Foundation also exports the legacy MacTypes `Point`, `Rect` and `Size`.
// Declarations in this module shadow imported ones, so these keep the tests unambiguous.
typealias Rect = EspalierCore.Rect
typealias Point = EspalierCore.Point
typealias Size = EspalierCore.Size
