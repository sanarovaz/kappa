// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kappa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kappa",
            path: "Sources/BarraTicker"
        )
    ]
)
