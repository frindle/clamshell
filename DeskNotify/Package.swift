// swift-tools-version: 5.9
import PackageDescription

// Notification and Dock badge bridge (execution plan 3.3, rows "Notifications" and "Dock badges").
//  DeskNotify        pure logic and wire mapping: cursor, payload decoder, host bridge, badge diff,
//                    operator gate. Builds on Linux and macOS.
//  DeskNotifySQLite  reads the notification store through SQLite (system library on Linux).
//  DeskNotifyMac     Accessibility reader for Dock badges. macOS only; empty elsewhere.
let package = Package(
    name: "DeskNotify",
    products: [
        .library(name: "DeskNotify", targets: ["DeskNotify"]),
        .library(name: "DeskNotifySQLite", targets: ["DeskNotifySQLite"]),
        .library(name: "DeskNotifyMac", targets: ["DeskNotifyMac"]),
    ],
    dependencies: [
        .package(path: "../DeskProtocol"),
        .package(path: "../DeskStubs"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .target(name: "DeskNotify", dependencies: [
            .product(name: "DeskProtocol", package: "DeskProtocol"),
            .product(name: "DeskStubs", package: "DeskStubs"),
        ]),
        .target(name: "DeskNotifySQLite", dependencies: [
            "DeskNotify",
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]),
        .target(name: "DeskNotifyMac", dependencies: ["DeskNotify"]),
        .testTarget(name: "DeskNotifyTests", dependencies: [
            "DeskNotify", "DeskNotifySQLite", "DeskNotifyMac",
            .product(name: "DeskProtocol", package: "DeskProtocol"),
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
        ]),
    ]
)
