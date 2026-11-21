// swift-tools-version: 5.9
import PackageDescription

// Operator side of Desk, the Mac viewer for hosted app windows (execution plan 3.1).
//  DeskClient     pure logic, no Foundation and no Apple frameworks: runs on Linux and macOS.
//                 Control connection per host, reconnect, session list, window model, child
//                 window placement, resize policy.
//  DeskClientMac  the macOS-only decoder path (frame assembler, video layer view, key map,
//                 audio player). Its files are empty on other platforms.
let package = Package(
    name: "DeskClient",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DeskClient", targets: ["DeskClient"]),
        .library(name: "DeskClientMac", targets: ["DeskClientMac"]),
    ],
    dependencies: [
        .package(path: "../DeskProtocol"),
    ],
    targets: [
        .target(name: "DeskClient", dependencies: [
            .product(name: "DeskProtocol", package: "DeskProtocol"),
        ]),
        .target(name: "DeskClientMac", dependencies: [
            "DeskClient",
            .product(name: "DeskProtocol", package: "DeskProtocol"),
        ]),
        .testTarget(name: "DeskClientTests", dependencies: [
            "DeskClient",
            .product(name: "DeskProtocol", package: "DeskProtocol"),
        ]),
    ]
)
