// swift-tools-version: 5.9
import PackageDescription

// Stub app generator (execution plan 3.1 "StubApps" and 9.2).
//  DeskStubs      pure logic: what stubs should exist and what is in each bundle. No Foundation.
//  DeskStubsDisk  writes a bundle to disk (Foundation; runs on Linux and macOS).
//  desk-stubgen   command line that applies a plan; on macOS it signs each bundle (ad hoc by
//                 default) before putting it in place. The macOS CI job checks real bundles.
let package = Package(
    name: "DeskStubs",
    products: [
        .library(name: "DeskStubs", targets: ["DeskStubs"]),
        .executable(name: "desk-stubgen", targets: ["desk-stubgen"]),
    ],
    targets: [
        .target(name: "DeskStubs"),
        .target(name: "DeskStubsDisk", dependencies: ["DeskStubs"]),
        .executableTarget(name: "desk-stubgen", dependencies: ["DeskStubs", "DeskStubsDisk"]),
        .testTarget(name: "DeskStubsTests", dependencies: ["DeskStubs", "DeskStubsDisk"]),
    ]
)
