// swift-tools-version: 5.9
import PackageDescription

// Placer rule engine and state-cost table for moves (execution plan sections 3.2 and 9.3).
// Pure logic, no Foundation and no Apple frameworks: it builds and tests on Linux.
let package = Package(
    name: "DeskPlacer",
    products: [
        .library(name: "DeskPlacer", targets: ["DeskPlacer"]),
    ],
    targets: [
        .target(name: "DeskPlacer"),
        .testTarget(name: "DeskPlacerTests", dependencies: ["DeskPlacer"]),
    ]
)
