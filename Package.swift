// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sauron",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Sauron", path: "Sources/Sauron")
    ]
)
