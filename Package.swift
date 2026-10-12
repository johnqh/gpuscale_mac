// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gpuscale",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "gpuscale",
            path: "Sources/gpuscale"
        )
    ],
    // Build in Swift 5 language mode: this tool uses a handful of AVFoundation
    // APIs that are deprecated (but fully functional) under the macOS 27 SDK and
    // would be hard errors under Swift 6's strict concurrency checking.
    swiftLanguageVersions: [.v5]
)
