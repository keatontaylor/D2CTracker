// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "D2CTrackerCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "D2CTrackerCore", targets: ["D2CTrackerCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/gavineadie/SatelliteKit.git", exact: "2.1.0")
    ],
    targets: [
        .target(
            name: "D2CTrackerCore",
            dependencies: ["SatelliteKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "D2CTrackerCoreTests",
            dependencies: ["D2CTrackerCore"]
        )
    ]
)
