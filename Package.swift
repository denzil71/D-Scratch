// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DScratch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DScratch",
            path: "Sources/DScratch"
        )
    ]
)
