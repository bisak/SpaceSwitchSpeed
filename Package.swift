// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpaceSwitchSpeed",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SpaceSwitchSpeedKit", targets: ["SpaceSwitchSpeedKit"]),
        .executable(name: "spaceswitchspeed", targets: ["spaceswitchspeed"]),
    ],
    targets: [
        .target(name: "SpaceSwitchSpeedKit"),
        .executableTarget(name: "spaceswitchspeed", dependencies: ["SpaceSwitchSpeedKit"]),
        .executableTarget(name: "dock-check", dependencies: ["SpaceSwitchSpeedKit"]),
        .testTarget(name: "SpaceSwitchSpeedKitTests", dependencies: ["SpaceSwitchSpeedKit"]),
    ]
)
