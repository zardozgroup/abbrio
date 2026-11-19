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
    name: "AbbrioUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AbbrioUI", targets: ["AbbrioUI"]),
    ],
    dependencies: [
        .package(path: "../SnippetModel"),
        .package(path: "../ConfigStore"),
        .package(path: "../EspansoCLI"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.17.0"),
    ],
    targets: [
        .target(
            name: "AbbrioUI",
            dependencies: ["SnippetModel", "ConfigStore", "EspansoCLI", "KeyboardShortcuts"],
            // The license texts of the third-party code the app contains, shown in the About window.
            resources: [.copy("Licenses")],
            swiftSettings: settings + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "AbbrioUITests", dependencies: ["AbbrioUI"], swiftSettings: settings),
    ]
)
