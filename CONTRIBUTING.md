# Contributing to Abbrio

Thanks for taking the time to help. This page covers what you need to build Abbrio, how the code is split
up, how to test a change without risking anyone's real snippets, and what a pull request should look like.

For security problems, don't open an issue; follow [SECURITY.md](SECURITY.md) instead.


## Requirements

- Xcode 27
- Swift 6.4 (the toolchain that comes with Xcode 27)
- macOS 14 or later, both to build and to run the app
- Espanso 2.x, if you want to try the app against a running Espanso. The tests don't need it.


## Signing for local builds

You don't need an Apple developer account to build and run Abbrio.

`Config/Signing.xcconfig` is shared by everyone and signs ad hoc. If you want to sign with your own team
instead, for example to keep the Accessibility permission across rebuilds, copy the example file and put
your Team ID in it:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

Then replace `YOURTEAMID` with your Apple Team ID. `Config/Signing.local.xcconfig` is ignored by Git and
overrides the shared settings for Debug and Release. Don't change the signing settings in
`Abbrio.xcodeproj` or `Config/Signing.xcconfig`, and never commit certificates, profiles or credentials.


## How the code is split up

The app target in `Abbrio/` is a thin shell. Almost everything lives in four local Swift packages under
`Packages/`, so the YAML and command-line code can be built and tested without the app.

| Package | What it holds | May depend on |
| --- | --- | --- |
| `SnippetModel` | Shared value types | Nothing |
| `ConfigStore` | Everything on disk: parsing, surgical YAML edits, the sidecar, statistics | `SnippetModel`, Yams |
| `EspansoCLI` | Finding the `espanso` program and running its commands | `SnippetModel`, swift-subprocess |
| `AbbrioUI` | Views and view models | All of the above, KeyboardShortcuts |

Keep these boundaries when you add code:

- `SnippetModel` has no dependencies at all.
- `ConfigStore` is the only package that imports Yams.
- `ConfigStore` and `EspansoCLI` don't depend on each other. Code that needs both belongs in `AbbrioUI`.
- The app target stays a thin shell. New views and logic go into the packages, not into `Abbrio/`.

Abbrio talks to Espanso only by running the user's installed `espanso` program and by editing its config
files. Espanso is GPL-3.0 licensed: don't copy its source code, tests, default configs or documentation
text into this repository, and don't link against it or bundle it.

The design is in `espanso gui ux spec.md`, and `docs/espanso-facts.md` records how Espanso was found to
behave. Where the two disagree, `docs/espanso-facts.md` wins. If a change needs behavior that neither
covers, open an issue to discuss it before you build it.


## Running the tests

Each package has its own tests, run from its folder:

```sh
cd Packages/SnippetModel && swift test
```

```sh
cd Packages/ConfigStore && swift test
```

```sh
cd Packages/EspansoCLI && swift test
```

```sh
cd Packages/AbbrioUI && swift test
```

The app target is tested with:

```sh
xcodebuild -project Abbrio.xcodeproj -scheme Abbrio test
```

Run the tests for every package you touched, and the app tests if you changed the app target or anything
it uses, before you open a pull request.


## Never use your real Espanso config

Development runs and tests must not read or write your real Espanso config
(`~/Library/Application Support/espanso` or `~/.config/espanso`). A bug in a writer could damage snippets
you rely on.

- The shared `Abbrio` scheme sets `ABBRIO_CONFIG_TEMPLATE` to the sample config in
  `Packages/ConfigStore/Tests/ConfigStoreTests/Fixtures/sample`. At each launch the app copies that folder
  to a temporary place and works on the copy, so the repository and your own config stay as they are.
  Leave it switched on when you run the app from Xcode.
- `ABBRIO_CONFIG_DIR` points the app at a folder you choose, used as it is. Use it only with a throwaway
  folder.
- Tests use fixture folders in the repository or a temporary directory, never the real config.
- Don't run `espanso match exec` or anything else that types text from a script or test. It types into
  whichever app is in front and deletes text before the cursor.

If you need a running Espanso to check a change, start one against a throwaway config folder as described
in "Running Espanso against a throwaway config" in `docs/espanso-facts.md`, and restore your normal
service afterwards with `espanso service start`.


## YAML golden-file tests

The YAML files are the source of truth, and many users keep comments and their own formatting in them.
Abbrio edits only the bytes of the match being changed and leaves the rest of the file byte for byte.

Any change to code that writes YAML needs golden-file tests in `Packages/ConfigStore`. The fixtures live in
`Tests/ConfigStoreTests/Fixtures/golden`; `MatchFileEditorTests.swift` shows the pattern. A golden test:

1. starts from a fixture file with comments, unusual quoting and several matches,
2. makes one edit through the same code the app uses,
3. compares the result with an expected file in the fixtures folder, and
4. checks that every line outside the edited match is unchanged.

When you add a case, write the expected file by hand and check it, rather than saving whatever the code
produced. New parsing logic also needs tests. Don't write matches with `Yams.serialize`; the app has its
own emitter so it can keep the user's formatting.


## Dependencies and licences

Abbrio is MIT licensed, and every dependency must be compatible with that. Only packages under the MIT,
BSD, Apache-2.0 or ISC licences are accepted. If a package is under a copyleft licence (GPL, LGPL, AGPL,
MPL) or its licence is unclear, open an issue first instead of adding it.

Every third-party dependency, including ones pulled in by another package, is listed with its version and
licence in [docs/dependencies.md](docs/dependencies.md), and the About window shows the same list with each
licence in full. Update the table, the About window's list and the licence text in the same pull request
that adds or upgrades the dependency; that file says where each one lives. Fewer dependencies are better: if the
system frameworks can do the job, use them.

Sample snippets and fixtures must be your own work. Don't copy built-in sets, help text, icons or artwork
from other text expanders.


## Pull requests

- Open an issue first for anything larger than a small fix, so we can agree on the approach before you
  spend time on it.
- Keep each pull request to one change. Unrelated clean-ups go in a separate pull request.
- Branch from `main` and keep your branch up to date with it.
- Describe what changed and why, and how you checked it: which tests you ran and, for UI changes, what you
  tried in the app. Screenshots in light and dark appearance help for anything visible.
- Add or update tests for new behavior. Anything that writes YAML needs golden-file tests.
- Make sure the package and app tests pass.
- Follow the style of the surrounding code and the Swift API Design Guidelines. UI should follow the macOS
  Human Interface Guidelines and use system colors so it works in light and dark appearance.
- Update `README.md`, `docs/` or the spec when you change behavior they describe.
- Don't commit build output, `xcuserdata/`, `Config/Signing.local.xcconfig` or anything with credentials.

By contributing, you agree that your contribution is released under the project's [MIT License](LICENSE).
