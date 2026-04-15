// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AirBridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/AirBridge"
        ),
        .testTarget(
            name: "AirBridgeTests",
            dependencies: [
                "AirBridge",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/AirBridgeTests"
        ),
    ]
)
