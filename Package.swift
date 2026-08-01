// swift-tools-version:5.9
import PackageDescription

#if os(Linux)
let excludedSources = [
    "DiskInventoryZedApp.swift",
    "Utilities/Formatters.swift",
    "ViewModels",
    "Views"
]
#else
let excludedSources: [String] = []
#endif

let package = Package(
    name: "DiskInventoryZed",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DiskInventoryZed", targets: ["DiskInventoryZed"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "DiskInventoryZed",
            dependencies: [
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                )
            ],
            path: "Sources",
            exclude: excludedSources
        ),
        .testTarget(
            name: "DiskInventoryZedTests",
            dependencies: ["DiskInventoryZed"],
            path: "Tests"
        )
    ]
)
