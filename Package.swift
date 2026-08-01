// swift-tools-version:5.9
import PackageDescription

#if os(Linux)
let excludedSources = [
    "Analysis/DuplicateVerifier.swift",
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
    targets: [
        .executableTarget(
            name: "DiskInventoryZed",
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
