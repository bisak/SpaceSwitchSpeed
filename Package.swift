// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpaceSwitchKit", targets: ["SpaceSwitchKit"]),
        .executable(name: "spaceswitch", targets: ["spaceswitch"]),
        .executable(name: "SpaceSwitchApp", targets: ["SpaceSwitchApp"]),
    ],
    targets: [
        .target(name: "SpaceSwitchKit"),
        .executableTarget(name: "spaceswitch", dependencies: ["SpaceSwitchKit"]),
        .executableTarget(
            name: "SpaceSwitchApp",
            dependencies: ["SpaceSwitchKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SpaceSwitchKitTests", dependencies: ["SpaceSwitchKit"]),
    ]
)
