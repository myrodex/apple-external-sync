// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleExternalSync",
    defaultLocalization: "en",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SyncDomain", targets: ["SyncDomain"]),
        .library(name: "SyncContracts", targets: ["SyncContracts"]),
        .library(name: "SyncAdapters", targets: ["SyncAdapters"]),
        .library(name: "SyncStore", targets: ["SyncStore"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "SyncAppSupport", targets: ["SyncAppSupport"]),
        .library(name: "ExternalSync", targets: ["ExternalSync"])
    ],
    targets: [
        .target(name: "SyncDomain", path: "Sources/SyncDomain"),
        .target(name: "SyncContracts", dependencies: ["SyncDomain"], path: "Sources/SyncContracts"),
        .target(name: "SyncAdapters", dependencies: ["SyncDomain", "SyncContracts"], path: "Sources/SyncAdapters"),
        .target(name: "SyncStore", dependencies: ["SyncDomain"], path: "Sources/SyncStore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "SyncEngine", dependencies: ["SyncDomain", "SyncContracts", "SyncStore"], path: "Sources/SyncEngine"),
        .target(name: "SyncAppSupport", dependencies: ["SyncDomain", "SyncContracts", "SyncAdapters", "SyncEngine", "SyncStore"], path: "Sources/SyncAppSupport"),
        .target(name: "ExternalSync", dependencies: ["SyncAppSupport"], path: "Sources/ExternalSync"),
        .testTarget(name: "SyncDomainTests", dependencies: ["SyncDomain"], path: "Tests/SyncDomainTests"),
        .testTarget(name: "SyncAdaptersTests", dependencies: ["SyncAdapters", "SyncContracts", "SyncDomain"], path: "Tests/SyncAdaptersTests"),
        .testTarget(name: "SyncStoreTests", dependencies: ["SyncStore", "SyncDomain"], path: "Tests/SyncStoreTests"),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine", "SyncAdapters", "SyncContracts", "SyncDomain", "SyncStore"], path: "Tests/SyncEngineTests"),
        .testTarget(name: "ExternalSyncTests", dependencies: ["ExternalSync"], path: "Tests/ExternalSyncTests")
    ]
)
