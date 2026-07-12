// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clamshell",
    platforms: [.macOS(.v13)],
    targets: [
        // Declarations for the private CoreGraphics virtual-display classes
        // (CGVirtualDisplay & friends). Header-only; the classes are exported
        // by CoreGraphics at runtime.
        .target(name: "CGVirtualDisplayShim"),
        .executableTarget(
            name: "Clamshell",
            dependencies: ["CGVirtualDisplayShim"]
        ),
    ]
)
