// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Espalier",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EspalierCore", targets: ["EspalierCore"]),
        .executable(name: "Espalier", targets: ["Espalier"]),
    ],
    targets: [
        // Platform-independent layout engine: builds and tests on Linux and macOS.
        .target(name: "EspalierCore"),
        // The macOS app. Every source file is wrapped in `#if os(macOS)`, so the
        // package still builds on Linux, where the executable only prints a notice.
        .executableTarget(name: "Espalier", dependencies: ["EspalierCore"]),
        .testTarget(name: "EspalierCoreTests", dependencies: ["EspalierCore"]),
    ]
)
