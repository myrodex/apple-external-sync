// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SyncRelay",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.4")
    ],
    targets: [
        .executableTarget(
            name: "SyncRelay",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Sources/SyncRelay"
        ),
        .testTarget(
            name: "SyncRelayTests",
            dependencies: [
                .target(name: "SyncRelay"),
                .product(name: "VaporTesting", package: "vapor")
            ],
            path: "Tests/SyncRelayTests"
        )
    ]
)
