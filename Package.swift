// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.7.0"),
        .package(url: "https://github.com/adam-fowler/swift-srp.git", from: "2.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "AirBridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
                .product(name: "SRP", package: "swift-srp"),
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
