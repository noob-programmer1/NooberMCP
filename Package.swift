// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NooberMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/noob-programmer1/Noober-iOS.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "NooberMCP",
            dependencies: [
                .product(name: "NooberShared", package: "Noober-iOS"),
            ],
            path: "Sources"
        )
    ]
)
