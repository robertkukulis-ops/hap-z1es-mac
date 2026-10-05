// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HAPKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HAPKit", targets: ["HAPKit"]),
        .executable(name: "hap", targets: ["hap"]),
    ],
    targets: [
        // Everything that talks to the player.
        .target(name: "HAPKit", linkerSettings: [.linkedFramework("NetFS")]),
        // Small Terminal tool for trying HAPKit on the real player.
        .executableTarget(name: "hap", dependencies: ["HAPKit"]),
        // Tests run against replies saved from the real player, never the player itself.
        .testTarget(
            name: "HAPKitTests",
            dependencies: ["HAPKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
