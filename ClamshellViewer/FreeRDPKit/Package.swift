// swift-tools-version: 5.9
import PackageDescription

// Local package wrapping FreeRDP for the RDP connection mode in
// ClamshellViewer. Two targets, same shape as the root package's
// CGVirtualDisplayShim: a binary target vending a prebuilt C library, and a
// thin Objective-C bridge target on top of it that Swift actually imports.
//
// CFreeRDP.xcframework is NOT built by this package — it's a vendored,
// prebuilt static lib (libfreerdp + libwinpr + libfreerdp-client + OpenSSL,
// merged) produced by scripts/build-freerdp-ios.sh at the repo root. FreeRDP
// is a CMake project with a real cross-compile story (OpenSSL, per-arch
// toolchain files); that doesn't fit inside SwiftPM's own build graph the
// way CGVirtualDisplayShim's header-only target does, so the binary is
// checked in and the script is how you regenerate it (new FreeRDP version,
// new OpenSSL version, adding an arch slice). See that script's header
// comment for the one-time build (~10-15 min).
let package = Package(
    name: "FreeRDPKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "RDPBridge", targets: ["RDPBridge"]),
    ],
    targets: [
        .binaryTarget(name: "CFreeRDP", path: "CFreeRDP.xcframework"),
        .target(
            name: "RDPBridge",
            dependencies: ["CFreeRDP"],
            linkerSettings: [
                // FreeRDP/WinPR pull these in on Apple platforms; the static
                // xcframework doesn't carry transitive link flags, so they're
                // declared here once instead of in every consumer.
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("z"),
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
