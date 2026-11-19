# Abbrio

Abbrio is a native macOS app for people who use the [Espanso](https://espanso.org) text expander and would
rather manage their abbreviations in a window than in YAML files. It gives you a three-pane editor, a menu
bar companion and a Quick Search panel.

Espanso stays the engine. Abbrio reads and writes Espanso's own files and runs the `espanso` command you
already have installed, so everything you set up in Abbrio keeps working without it.

Abbrio is an independent project. It is not affiliated with or endorsed by the Espanso project.


## What it does

- **Edit abbreviations in a three-pane window:** sets on the left, items in the middle, details on the
  right, with search across all sets.
- **Keep your files as they are:** an edit changes only the item you edited. Comments, ordering and
  formatting elsewhere in the file are left byte for byte, and a backup is kept.
- **Dynamic content without writing YAML:** dates, the clipboard, the cursor position, forms, choices,
  random text, shell commands and scripts are inserted from a menu and shown as chips in the text.
- **Text, Markdown, HTML and pictures** as expansion types.
- **Sets:** turn them on and off, give them a prefix or suffix, default options and notes.
- **Per-application settings:** choose which sets are active in which apps. Abbrio writes the Espanso config
  files for you.
- **Regular expression rules** with a tester and warnings for syntax Espanso does not accept.
- **Quick Search:** a floating panel, opened with a global shortcut, that finds an abbreviation and inserts
  it into the app you were working in.
- **Menu bar companion:** pause, resume and restart Espanso, and create an item from the clipboard or the
  selection.
- **Packages:** browse the Espanso Hub, read a package's README and triggers before installing, and install,
  update or uninstall. Packages can also be installed from a git repository.
- **Statistics:** how often each abbreviation was used, from Espanso's own counts.
- **Settings:** Espanso's options in `config/default.yml`, edited one key at a time.
- **Import and export:** CSV or TSV in, CSV out, and export of a set as an Espanso package.

## Requirements

- macOS 14 or later
- Espanso 2.x, installed and started once. Statistics need Espanso 2.4.0 or later.

Quick Search needs the Accessibility permission, because it pastes into other apps. It is the only place
where Abbrio sends keystrokes.

## Building

You need Xcode with a Swift 6.4 toolchain.

1. Clone the repository.
2. Open `Abbrio.xcodeproj`.
3. Run the `Abbrio` scheme.

Local builds use ad hoc signing and do not need an Apple developer account. To use your own development
certificate, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and replace
`YOURTEAMID` with your Apple Team ID. The local file is ignored by Git and overrides the shared signing
defaults for both Debug and Release. Keep certificates and credentials in Keychain; do not change the
shared project's signing settings to add your team.

The shared scheme sets `ABBRIO_CONFIG_TEMPLATE`, which copies the sample config in the repository to a
temporary folder at each launch. That way a development run never touches your real Espanso config. Switch
the variable off in the scheme to work on your real config instead.

| Variable | Effect |
| --- | --- |
| `ABBRIO_CONFIG_TEMPLATE` | Copy this folder to a temporary place and use the copy |
| `ABBRIO_CONFIG_DIR` | Use this config folder as it is |
| `ABBRIO_ESPANSO_BINARY` | Use this `espanso` program instead of the one found |

For signed DMG packaging and GitHub Releases, see [Distributing Abbrio](docs/releases.md).

## Tests

Each package has its own tests:

```sh
cd Packages/ConfigStore && swift test
```

The same works in `Packages/SnippetModel`, `Packages/EspansoCLI` and `Packages/AbbrioUI`. The app target is
tested with:

```sh
xcodebuild -project Abbrio.xcodeproj -scheme Abbrio test
```

Tests run on fixture folders and never read or write your Espanso config.

## How the code is laid out

| Path | What it holds |
| --- | --- |
| `Abbrio/` | The app target, a thin shell around the packages |
| `Packages/SnippetModel` | Shared value types, with no dependencies |
| `Packages/ConfigStore` | Everything on disk: parsing, surgical YAML edits, the sidecar, statistics |
| `Packages/EspansoCLI` | Finding the `espanso` program and running its commands |
| `Packages/AbbrioUI` | Views and view models |
| `docs/` | Findings about Espanso's behavior, mockups and the list of dependencies |
| `espanso gui ux spec.md` | The design: behavior, YAML output and file handling |

Settings that only Abbrio uses, such as a set's display name or notes, are kept in
`.abbrio/metadata.json` inside the Espanso config folder, never in Espanso's YAML.

## Help

- [Help center](https://getabbrio.com/help/)
- [Ask for support](https://github.com/zardozgroup/abbrio/issues/new?template=general-support-request.md)
- [Report a bug](https://github.com/zardozgroup/abbrio/issues/new?template=bug_report.md)

The same three choices are behind the Help button in the app's toolbar.

## Contributing and security

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers building, the package layout, tests
and what a pull request needs. To report a security problem, follow [SECURITY.md](SECURITY.md) instead of
opening a public issue.

## License

Abbrio is released under the [MIT License](LICENSE). Third-party packages and their licenses are listed in
[docs/dependencies.md](docs/dependencies.md).

Espanso is a separate program under its own license. Abbrio does not include or link any of its code.
