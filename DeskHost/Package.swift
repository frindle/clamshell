// swift-tools-version: 5.9
import PackageDescription

// Host side of Window Handoff v3 (app-host), execution plan section 3.1.
// Pure logic, no Foundation and no Apple frameworks: it builds and tests on Linux.
// Launching apps, listing windows, capture and input sit behind protocols; the
// Clamshell app target supplies the macOS versions (Sources/Clamshell/AppHost/).
let package = Package(
    name: "DeskHost",
    products: [
        .library(name: "DeskHost", targets: ["DeskHost"]),
    ],
    dependencies: [
        .package(path: "../DeskProtocol"),
    ],
    targets: [
        .target(name: "DeskHost", dependencies: [.product(name: "DeskProtocol", package: "DeskProtocol")]),
        .testTarget(name: "DeskHostTests", dependencies: ["DeskHost"]),
    ]
)
