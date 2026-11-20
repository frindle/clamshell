// swift-tools-version: 5.9
import PackageDescription

// Window Handoff v3 (app-host) wire format. Pure logic, no Foundation and no
// Apple frameworks, so it builds and tests on Linux. The Clamshell app target
// will depend on it once the app-host code lands.
let package = Package(
    name: "DeskProtocol",
    products: [
        .library(name: "DeskProtocol", targets: ["DeskProtocol"]),
    ],
    targets: [
        .target(name: "DeskProtocol"),
        .testTarget(name: "DeskProtocolTests", dependencies: ["DeskProtocol"]),
    ]
)
