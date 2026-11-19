// swift-tools-version: 6.4
import PackageDescription

// Language features that become the default in Swift 7, adopted early.
let settings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "ConfigStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConfigStore", targets: ["ConfigStore"]),
    ],
    dependencies: [
        .package(path: "../SnippetModel"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
    ],
    targets: [
        .target(
            name: "ConfigStore",
            dependencies: [
                "SnippetModel",
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: settings
        ),
        .testTarget(
            name: "ConfigStoreTests",
            dependencies: ["ConfigStore"],
            resources: [.copy("Fixtures")],
            swiftSettings: settings
        ),
    ]
)
