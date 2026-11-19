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
    name: "SnippetModel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnippetModel", targets: ["SnippetModel"]),
    ],
    targets: [
        .target(name: "SnippetModel", swiftSettings: settings),
        .testTarget(name: "SnippetModelTests", dependencies: ["SnippetModel"], swiftSettings: settings),
    ]
)
