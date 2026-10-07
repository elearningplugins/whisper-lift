// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GarageTilesKit",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [
        .library(name: "GarageTilesKit", targets: ["GarageTilesKit"]),
        .library(name: "GarageDoorKit", targets: ["GarageDoorKit"]),
    ],
    targets: [
        .target(name: "GarageTilesKit"),
        // Door, token and myQ client logic for Phases 4 to 7; the Phase 0 spike app does not link it.
        .target(name: "GarageDoorKit"),
        // Seeded property-test harness shared by the test targets only.
        .target(name: "PropertyTestSupport", path: "Sources/PropertyTestSupport"),
        .testTarget(name: "GarageTilesKitTests", dependencies: ["GarageTilesKit", "PropertyTestSupport"]),
        .testTarget(name: "GarageDoorKitTests", dependencies: ["GarageDoorKit", "PropertyTestSupport"]),
    ]
)
