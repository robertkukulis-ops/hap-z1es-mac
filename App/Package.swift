// swift-tools-version: 6.0
import PackageDescription

// The Mac app (for now started with `swift run`; a proper .app bundle comes later via Xcode).
let package = Package(
    name: "HAPApp",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../HAPKit")],
    targets: [
        .executableTarget(
            name: "HAPPlayer",
            dependencies: [.product(name: "HAPKit", package: "HAPKit")]
        ),
        // Tests of the app's own logic (knobs, rack state); never talk to the player.
        .testTarget(name: "HAPPlayerTests", dependencies: ["HAPPlayer"]),
    ]
)
