// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpaceSwitch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpaceSwitchKit", targets: ["SpaceSwitchKit"]),
        .executable(name: "spaceswitch", targets: ["spaceswitch"]),
    ],
    targets: [
        .target(name: "SpaceSwitchKit", swiftSettings: .strict),
        .executableTarget(name: "spaceswitch", dependencies: ["SpaceSwitchKit"], swiftSettings: .strict),
        .testTarget(name: "SpaceSwitchKitTests", dependencies: ["SpaceSwitchKit"], swiftSettings: .strict),
    ]
)

extension [SwiftSetting] {
    /// Swift 6 language mode: data-race safety is checked at compile time.
    static var strict: [SwiftSetting] { [.swiftLanguageMode(.v6)] }
}
