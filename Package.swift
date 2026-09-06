// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Overpass",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Overpass",
            path: "Sources/Overpass"
        )
    ]
)
