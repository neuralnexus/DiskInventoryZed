// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskInventoryZed",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DiskInventoryZed", targets: ["DiskInventoryZed"])
    ],
    targets: [
        .executableTarget(
            name: "DiskInventoryZed",
            path: "Sources",
            exclude: []
        )
    ]
)