// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SoundRouter",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SoundRouter", path: "Sources/SoundRouter",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
