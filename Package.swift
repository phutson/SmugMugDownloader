// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmugMugDownloader",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SmugMugDownloader",
            path: "Sources/SmugMugDownloader"
        )
    ]
)
