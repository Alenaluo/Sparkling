// swift-tools-version: 6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Sparkling",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sparkling", targets: ["Sparkling"]),
        .executable(name: "ideactl", targets: ["ideactl"]),
    ],
    targets: [
        .target(name: "IdeaCore", swiftSettings: v5),
        .target(name: "IdeaUI", dependencies: ["IdeaCore"], swiftSettings: v5),
        .executableTarget(name: "Sparkling", dependencies: ["IdeaUI", "IdeaCore"], swiftSettings: v5),
        .executableTarget(name: "ideactl", dependencies: ["IdeaCore"], swiftSettings: v5),
        .testTarget(name: "IdeaCoreTests", dependencies: ["IdeaCore"], swiftSettings: v5),
        .testTarget(name: "IdeaUITests", dependencies: ["IdeaUI", "IdeaCore"], swiftSettings: v5),
    ]
)
