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
    name: "EspansoCLI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EspansoCLI", targets: ["EspansoCLI"]),
    ],
    dependencies: [
        .package(path: "../SnippetModel"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "EspansoCLI",
            dependencies: [
                "SnippetModel",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            swiftSettings: settings
        ),
        .testTarget(name: "EspansoCLITests", dependencies: ["EspansoCLI"], swiftSettings: settings),
    ]
)
