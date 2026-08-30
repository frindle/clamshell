// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clamshell",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Action-bound challenge signing with a YubiKey PIV slot as the key
        // device. Clamshell is a thin consumer: the core (challenge format,
        // verification, PIV transport) lives and is tested over there.
        .package(url: "https://github.com/frindle/immurok-yk.git", branch: "master"),
    ],
    targets: [
        // Declarations for the private CoreGraphics virtual-display classes
        // (CGVirtualDisplay & friends). Header-only; the classes are exported
        // by CoreGraphics at runtime.
        .target(name: "CGVirtualDisplayShim"),
        // Declaration for the private _AXUIElementGetWindow function (see its
        // header comment). Header-only; exported by ApplicationServices at
        // runtime.
        .target(name: "AXPrivateShim"),
        .executableTarget(
            name: "Clamshell",
            dependencies: [
                "CGVirtualDisplayShim",
                "AXPrivateShim",
                .product(name: "ImmurokKit", package: "immurok-yk"),
            ],
            resources: [.copy("Resources/novnc"), .copy("Resources/webclient")]
        ),
    ]
)
