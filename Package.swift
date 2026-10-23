// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSIN",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SSIN",
            path: "Sources/SSIN",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
