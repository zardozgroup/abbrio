# Third-party dependencies

Every dependency of the app, with its license. The About window lists the same entries and shows each
license in full. Check the license before adding a package: MIT, BSD, Apache-2.0 and ISC are fine.

| Package | Version | License | Used by | Purpose |
| --- | --- | --- | --- | --- |
| [Yams](https://github.com/jpsim/Yams) | 6.2.2 | MIT | `ConfigStore` | Parsing YAML and reporting where each node starts |
| [swift-subprocess](https://github.com/swiftlang/swift-subprocess) | 1.0.2 | Apache-2.0 | `EspansoCLI` | Running the `espanso` program and collecting its output |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 1.17.0 | MIT | `AbbrioUI` | The global hotkey that opens Quick Search |
| [swift-system](https://github.com/apple/swift-system) | 1.8.1 | Apache-2.0 with Runtime Library Exception | swift-subprocess | File paths and descriptors for swift-subprocess |

Yams bundles LibYAML, which is also MIT licensed.

When you add or upgrade a dependency, change this table, the list in
`Packages/AbbrioUI/Sources/AbbrioUI/AboutWindow.swift` and the license texts in
`Packages/AbbrioUI/Sources/AbbrioUI/Licenses/` together. A test in `AbbrioUI` fails when the table and
the About window disagree.

Espanso is not a dependency. The app runs the user's installed `espanso` program as a separate process and
does not include or link any of its code.
