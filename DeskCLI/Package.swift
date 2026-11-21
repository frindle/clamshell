// swift-tools-version: 5.9
import PackageDescription

// The `desk` command line (execution plan 3.2, 3.5, 9.2 and 9.3): open, stub-run, move and mem.
//  DeskCLICore  all the logic. Every system action sits behind a protocol, so tests use fakes.
//               No Apple frameworks, so it builds and tests on Linux.
//  desk         the executable. On macOS it supplies the real implementations of the protocols.
let package = Package(
    name: "DeskCLI",
    products: [
        .library(name: "DeskCLICore", targets: ["DeskCLICore"]),
        .executable(name: "desk", targets: ["desk"]),
    ],
    dependencies: [
        .package(path: "../DeskPlacer"),
        .package(path: "../DeskProtocol"),
    ],
    targets: [
        .target(name: "DeskCLICore", dependencies: [
            .product(name: "DeskPlacer", package: "DeskPlacer"),
            .product(name: "DeskProtocol", package: "DeskProtocol"),
        ]),
        .executableTarget(name: "desk", dependencies: ["DeskCLICore"]),
        .testTarget(name: "DeskCLITests", dependencies: ["DeskCLICore"]),
    ]
)
