# Espanso facts

Findings from the Phase 0 spikes. Where this file and the UX spec disagree, this file wins.

Tested on 2026-11-11 with Espanso 2.4.1 (Homebrew cask, `/Applications/Espanso.app`) on macOS 26.7.1, Apple silicon.

## Status

| # | Question | Status |
| --- | --- | --- |
| 1 | What `filter_class` and `filter_exec` see | **Answered** |
| 2 | Default case sensitivity, `propagate_case` with capitals | **Answered** |
| 3 | `excludes` / `extra_excludes` in `default.yml` | **Answered** |
| 4 | `match exec` from a panel, focus delay | **Answered**, with a problem: `match exec` deletes text before the cursor. Pasting the trigger first works (checked 2026-11-13). Delays under 200 ms untested |
| 5 | `stats --json` output and `--period` values | **Answered** |
| 6 | Real default of `max_regex_buffer_size` | **Answered**: 30 |
| 7 | Script paths into `$CONFIG/scripts/` | **Answered** |
| 8 | Can the app tell that Espanso is paused | **Answered** |
| 9 | Source positions from Yams | **Answered** |
| 10 | Does Espanso ignore `.abbrio/` | **Answered** |
| 11 | Hub index, package subcommands, reload after install | **Answered** |
| 12 | Naming the process that holds Secure Input | **Answered** through Espanso's log; the `ioreg` route is unverified |

## Running Espanso against a throwaway config

This is how every spike was run, and how development and manual tests should run.

- Espanso reads three environment variables: `ESPANSO_CONFIG_DIR`, `ESPANSO_PACKAGE_DIR` and `ESPANSO_RUNTIME_DIR`. `espanso path` reflects them.
- With only `ESPANSO_CONFIG_DIR` set, the package folder follows it (`$CONFIG/match/packages`). Setting `ESPANSO_PACKAGE_DIR` to a folder outside `$CONFIG/match` installs packages there, but their matches are then not loaded. Leave it unset.
- A separate `ESPANSO_RUNTIME_DIR` gives the instance its own lock files, sockets, log (`espanso.log`), stats and package index cache.
- The config folder must already contain `config/default.yml`; without it every command panics with "missing default config".
- Start the instance as its own app so macOS applies Espanso's own Accessibility grant:

  ```
  espanso service stop
  open -a /Applications/Espanso.app \
    --env ESPANSO_CONFIG_DIR=<dir>/cfg --env ESPANSO_RUNTIME_DIR=<dir>/run
  ```

  Starting it from a shell with `espanso service start --unmanaged` timed out: the launcher came up but no daemon followed.
- A fresh runtime folder makes the launcher show its first-run wizard and wait. Copying the three flag files from `~/Library/Caches/espanso/kvs/` (`has_completed_wizard`, `has_displayed_welcome`, `has_selected_auto_start_option`, each containing `true`) into `<run>/kvs/` skips it.
- CLI calls need the same variables in their environment to reach that instance.
- Keep the runtime folder's path short. Espanso puts Unix sockets in it, and with a long path the daemon and worker stop with "path must be shorter than SUN_LEN". A path of about 50 characters works; one of about 130 does not. A short symlink to a longer folder is enough.
- Afterwards: quit the instance and run `espanso service start` to bring back the normal service.

## Spike 1 — what app filters see

Values shown by `#detect#`:

| App | title | exec | class |
| --- | --- | --- | --- |
| Mail | `New Message` | `/System/Applications/Mail.app` | `com.apple.mail` |
| VSCodium | `#d • Untitled-1` | `/Applications/VSCodium.app` | `com.vscodium` |
| Google Chrome | `<page title> - Google Chrome - <profile name>` | `/Applications/Google Chrome.app` | `com.google.Chrome` |

- `filter_class` matches the **bundle identifier**, in its original letter case.
- `filter_exec` matches the path of the **app bundle** (`…/Name.app`), not the executable inside it.
- `filter_title` matches the window title, which changes with the document and is no use for identifying an app.

**Consequences.** Generated app configs should filter on `filter_class` with the escaped bundle ID, anchored (`^com\.apple\.mail$`). It survives the app being moved or renamed, which a path does not. The example in the spec that uses `filter_exec` should change accordingly.

## Spike 2 — case sensitivity and `propagate_case`

Typed in TextEdit:

| Match | Typed | Result |
| --- | --- | --- |
| `trigger: ";cl"` | `;cl` | Expands |
| | `;CL` | Nothing |
| `trigger: ";Cu"` | `;Cu` | Expands |
| | `;cu` | Nothing |
| `trigger: ";alh"`, `propagate_case: true` | `;alh` / `;Alh` / `;ALH` | although / Although / ALTHOUGH |
| `trigger: ";Tmw"`, `propagate_case: true` | `;Tmw` / `;tmw` / `;TMW` | Tomorrow / tomorrow / TOMORROW |

- Triggers are case-sensitive by default. "Case must match" writes nothing.
- With `propagate_case`, a trigger that itself contains a capital still responds to the lowercase, Capitalized and UPPERCASE forms, and the output follows what was typed, not how the trigger is written.
- Espanso records each typed form as its own trigger in the statistics (`;alh`, `;Alh`, `;ALH`).

## Spike 3 — excludes in `default.yml`

`config/default.yml` accepts `excludes`, `extra_excludes` and `extra_includes`. Paths are relative to the `config/` folder. Checked with `espanso match list` (baseline 11 matches: 9 in `match/base.yml`, 2 from the `get-ip` package).

| Added to `default.yml` | Result |
| --- | --- |
| `extra_excludes: ["../match/packages/get-ip/*"]` | Package matches gone (9 left) |
| `excludes: ["../match/packages/get-ip/*"]` | Same |
| `extra_excludes: ["../match/packages/get-ip/package.yml"]` | Same |
| `extra_excludes: ["../match/packages/**/*"]` | All package matches gone |
| `extra_excludes: ["../match/base.yml"]` | Only the 2 package matches left |
| `extra_includes: ["../match/_off.yml"]` | The underscore file's match is loaded |

- A package can be switched off everywhere without uninstalling it.
- A file named `_off.yml` is not loaded unless something includes it, as documented.
- Prefer `extra_excludes` over `excludes`: `excludes` replaces Espanso's default exclude list instead of adding to it.
- An application config inherits each of these four keys from `default.yml` only when it leaves the key out. A key it does set replaces the same key in `default.yml`: with `extra_includes: ["../match/_shared.yml"]` in `default.yml` and `extra_includes: ["../match/_app.yml"]` in the application config, the application gets `_app.yml` and not `_shared.yml`. To keep both, the application config lists both. Across keys the lists still combine: an application's `extra_includes` adds to an inherited `includes`, and its `extra_excludes` to an inherited `excludes`. This comes from reading how Espanso resolves a config (`espanso-config/src/config/resolve.rs`, November 2026), not from a typing test.

## Spike 5 — statistics output (partial)

- `espanso stats --help` lists the period values: `today`, `week`, `month`, `year`, `all` (default `all`). An unknown value is not rejected; it exits 0 and returns the same empty result.
- Other options: `--count <n>` (default 10), `--grep <SQL LIKE pattern>`, `--json`. Subcommands: `clear`, `prune`.
- With stats enabled the worker logs `stats recorder initialized`; with them off it logs `stats recorder disabled by config`.
- JSON with no data:

  ```json
  { "top": [], "total": 0, "unique": 0 }
  ```

- With data, each `top` entry has exactly two fields:

  ```json
  { "top": [ { "count": 9, "trigger": ";cl" } ], "total": 21, "unique": 13 }
  ```

- `top` is sorted by count and cut at `--count`; `total` and `unique` cover the whole period. There are no timestamps and no per-day breakdown in the CLI output.
- `--grep` narrows `top`, `total` and `unique` together and ignores letter case (`;a%` returned `;alh`, `;Alh` and `;ALH`).
- **The recorded trigger is the text that was typed**, not the match's trigger as written in the file. Case variants are separate rows, and a regex match is recorded as the matched text (`=abcdefghijklmnopqrstuvwxyz=`), not the pattern.
- Expansions started with `espanso match exec` are counted like typed ones.
- The data lives in `$CONFIG/stats.db`, an SQLite database. Writing it does not restart the worker.

**Database layout** (2.4.1, from inspecting the file and reading how Espanso queries it):

- Table `triggers`: `id`, `name` (unique; the typed text).
- Table `expansions`: `id`, `trigger_id`, `timestamp`. One row per expansion. The timestamp is text in the form `2026-11-12 03:16:26`, in UTC.
- The database runs in WAL mode, so `stats.db-wal` and `stats.db-shm` sit next to it and a reader must open the file in place, read-only, not copy it.
- Period meanings: `today` is since midnight **UTC**, not local midnight; `week`, `month` and `year` are rolling windows of 7, 30 and 365 days; anything else means all time.
- The database is created only when `stats: enabled: true` is set; `stats clear` empties it and `stats prune --days N` deletes rows older than N days.

**Reading the database while Espanso uses it** (checked 2026-11-14).

- While the worker runs with statistics on, it keeps the database open and `stats.db-wal` and `stats.db-shm` exist. A read-only connection then sees rows that are still only in the write-ahead file.
- When the last connection closes (Espanso stops, or `espanso stats` runs with no worker), Espanso removes the two write-ahead files. The main file stays marked as write-ahead, and an ordinary read-only open then fails with "unable to open database file", because SQLite would have to create those files.
- The reader therefore opens the file as immutable when there is no `-wal` file (everything is in the main file then) and as an ordinary read-only connection when there is one. Neither creates or changes a file.
- With the app's reader and `espanso stats --json` run against the same throwaway instance, totals, unique counts and every per-trigger count were equal for week, month, year and all, and for today when the app was asked for midnight UTC. `stats prune --days 1` and `stats clear` left both reporting the same figures.
- `espanso stats clear` and `stats prune` ask for no confirmation and print nothing the app needs.

**Consequences.**

- The Statistics view has to map typed text back to matches itself: case variants fold into their match, and regex hits can only be attributed by running the set's patterns against the recorded text.
- A recents list or a chart over time is not available from the CLI. The app reads `stats.db` directly, read-only, with the system SQLite library. The layout is undocumented, so the reader checks that the two tables and their columns exist and falls back to `espanso stats --json` if they do not.
- Quick Search insertions show up in Espanso's statistics, so the app's own recents list and the stats can be merged without double counting only if the app does not also count them.

## Spike 4 — `match exec` from a panel

Test: a non-activating floating `NSPanel` opened with a global hotkey; Return hides the panel, waits, then runs `espanso match exec -t ";cl"`.

- **`match exec -t` deletes as many characters before the cursor as the trigger is long, then inserts the expansion.** It behaves as if the trigger had just been typed. Measured in a test window holding `12345` with the cursor at the end:

  | Trigger | Length | Text afterwards |
  | --- | --- | --- |
  | `;cl` | 3 | `12lower-trigger fired` |
  | `;alh` | 4 | `1although` |
  | `zqbtw` | 5 | `by the way` |

  `match exec` has no option to turn this off (its only options are `-t` and `--arg`). Quick Search therefore pastes plain-text snippets itself (clipboard plus ⌘V) and keeps `match exec` for snippets that need Espanso, pasting the trigger first so that the deleted characters are the ones just pasted. See "Pasting the trigger, then `match exec`" below for the check of that technique.
- With a 200 ms delay the text landed in TextEdit, Mail and Sublime Text.
- A non-activating panel never changes the frontmost app: it was the same app before the panel opened and at the moment of the exec. There is no focus to hand back, only key-window status.
- `match exec` returns in about 65 ms with exit code 0 and no output. It does not wait for the injection and does not report failure.
- Two execs within the same second run into each other: the second one's deletion removed the end of the first one's text ("lower-trigger filower-trigger fired"). The panel must not fire a second exec while one is in flight.
- Espanso holds an injection back while modifier keys are down and gives up with a log warning ("injection delay has timed out, please release the modifier keys"). Anything bound to a hotkey must wait for the modifiers to be released before calling `match exec`.
- Espanso types with the modifiers the system reports as down. A synthetic ⌘V whose key-up still carries the Command flag leaves Command reported as down: Espanso's Backspace then deletes the whole line and a space in the expansion opens Spotlight. The paste is therefore posted from a private event source with no flags on the key-up, and `match exec` is only called once no modifier is reported down.
- With no worker running, `match exec` exits with code 1 and prints `unable to exec match: Worker process is not running, please start Espanso first.`
- Not tested: delays shorter than 200 ms, and a browser text field. Tune the delay in Phase 5.

### Pasting the trigger, then `match exec`

Checked on 2026-11-13 in a test window holding `abc ` with the cursor at the end. The trigger was put on the clipboard and pasted, the clipboard was set back to `ORIGINAL`, and `espanso match exec -t <trigger>` was run 30 ms or 100 ms after the paste. Both delays gave the same result.

| Match | Text after the paste | Text afterwards |
| --- | --- | --- |
| `year {{y}} done`, a `date` variable | `abc ;p5date` | `abc year 2026 done` |
| `shell says {{out}}`, a `shell` variable | `abc ;p5sh` | `abc shell says hello` |
| `clip <{{c}}>`, a `clipboard` variable | `abc ;p5clip` | `abc clip <ORIGINAL>` |
| `before $|$ after` | `abc ;p5cur` | `abc before  after`, cursor between the two spaces |

- Espanso deletes exactly the pasted trigger and nothing in front of it.
- Restoring the clipboard before `match exec` runs is enough for a `clipboard` variable to see what the user had copied, not the trigger.
- The paste in this check was the text view's own Paste action, not a ⌘V key press, because the test program has no Accessibility permission. The app's ⌘V route is checked by hand.
- A match added to a file by the app was expanded the same way right after Espanso logged its reload.

## Spike 6 — `max_regex_buffer_size`

The default is **30**, as the options page says. With the regex `=(?P<body>[a-z]+)=`:

| Typed match length | Setting | Result |
| --- | --- | --- |
| 28 | default | Expands |
| 40 | default | Nothing |
| 40 | `max_regex_buffer_size: 50` | Expands |

The regex editor should warn when a pattern can match more than 30 characters, or more than the configured value.

### What the regex engine refuses

Checked on 2.4.1 by loading one rule of each kind and reading the log. A refused rule is skipped with an `[ERROR] unable to compile regex` line from the worker; the other rules in the file still load, and `espanso match list` shows the refused rule all the same.

| Pattern | Result |
| --- | --- |
| `=zq(?P<amount>\d+)usd=` | Loads |
| `=zw(?<b>\d+)=` | Refused: "unrecognized flag". Named groups must be spelled `(?P<name>…)`. |
| `=zx(\d+)=(?=z)` | Refused: "look-around, including look-ahead and look-behind, is not supported" |
| `=zy(a)\1=` | Refused: "backreferences are not supported" |

## Spike 7 — script paths

All three forms ran a script stored in `$CONFIG/scripts/`:

| Form | Works |
| --- | --- |
| `type: script`, `args: [/bin/sh, "/absolute/path/scripts/hello.sh"]` | Yes |
| `type: script`, `args: [/bin/sh, "%CONFIG%/scripts/hello.sh"]` | Yes |
| `type: shell`, `cmd: "sh \"$CONFIG/scripts/hello.sh\""` | Yes |

**Consequence.** Write `%CONFIG%/scripts/<file>` for `script` variables and `$CONFIG/scripts/<file>` for `shell` variables. Both keep working when the config folder is moved or synced to another Mac; an absolute path does not.

## Spike 8 — detecting a pause

- `espanso status` (an alias of `espanso service status`) prints `espanso is running` and exits 0 whether expansions are enabled or disabled. It cannot tell the two apart.
- `espanso cmd` has `enable`, `disable`, `toggle` and `search`. None of them reports the current state.
- The only signal found is the worker's log line, written on every change:

  ```
  [worker(4071)] [INFO] toggled enabled state, is_enabled = false
  ```

- Consequence: the app tracks pauses it makes itself, and can follow `<runtime>/espanso.log` for that line to catch pauses made elsewhere. A worker restart (any config reload) starts enabled again, so a `spawning the worker process` line resets the state.
- The toggle key (tested with `toggle_key: RIGHT_ALT`, double press) writes the same log line as `espanso cmd disable`, so following the log catches both.
- `espanso match exec` still inserts while expansions are disabled. Quick Search keeps working during a pause unless the app blocks it itself.
- A double press of right Option is also a common global shortcut in other apps; the Settings UI should warn about that when a toggle key is chosen.

## Spike 9 — YAML source positions

Prototype: Yams 6.2.2 (MIT), `Yams.compose(yaml:)`, on a fixture with comments, blank lines, a literal block, a flow-style match, an anchor, a merge key and non-ASCII text.

**What Yams gives.**

- Every `Node` has a `mark` with a 1-based line and column of its **start**. There is no end mark.
- The column counts characters, not UTF-8 bytes or UTF-16 units. Use the line number and work in bytes from the line start.
- For a block-style match the mark is the first key, on the dash line. For a flow-style match it is the `{`.
- Mapping key order is kept.
- Scalar style (plain, quoted, literal) is reported. Mapping style is always `any`, so flow style has to be detected from the source text.
- Anchors are not reported on the node. An alias resolves to the anchored node, whose mark points back at the anchor's position (an earlier line than its key). A merge key shows up as a key named `<<`.

**How ranges are derived.** Matches are whole lines, so line ranges are enough:

- start: the item's dash line
- end: the line before the next item's dash line, or before the next top-level key, or the end of the file; then trimmed back over trailing blank and comment lines
- leading comments: the unbroken run of comment lines directly above the dash line, at the dash's indentation or deeper

**Result.** Edit, delete (with its leading comment) and append each left every byte outside the touched range identical, and the result parsed again with the expected match count. The same held for a CRLF file.

**Consequences.**

- Yams is enough; there is no need to use libyaml's event API directly.
- Items needing "Advanced YAML" handling are found from the text and the marks: a line starting `- {`, a `&` anchor after the dash, a `<<` key, or a value whose mark lies outside the item's own line range.
- Do not use `Yams.serialize` to write a match. It escapes non-ASCII as `\U…`, writes multi-line text as an escaped double-quoted string instead of a literal block, and leaves `yes`-like strings unquoted. The app needs its own small emitter for the canonical style.
- New line endings must copy the file's existing ones.

## Spike 10 — the `.abbrio/` folder

Espanso's watcher covers the whole config folder, hidden folders included. It does not load anything from `.abbrio/`, and wrote no warnings, but some writes there restart the worker.

| Write inside the config folder | Worker restart |
| --- | --- |
| `.abbrio/metadata.json` written in place | No |
| `.abbrio/metadata.json` replaced by renaming a `.tmp` file over it | No |
| `.abbrio/backups/base.yml.2` | No |
| `.abbrio/backups/x.yml.bak` | No |
| `.abbrio/backups/x.yml` created or deleted | **Yes** |
| `.abbrio/x.yaml` | **Yes** |
| A file with no extension (`.abbrio/LOCK`, `README` at the root) | **Yes** |
| A folder created or removed, anywhere | **Yes** |
| `.json`, `.png`, `.txt` in an existing folder | No |
| `match/.base.yml.tmp` (hidden temp file) | No |
| A temp file renamed over `match/base.yml` | Yes, once |

The rule that fits: a change restarts the worker when the path ends in `.yml` or `.yaml`, or has no extension at all (which includes folders).

**Consequences.**

- The sidecar location is fine.
- Backup files must not end in `.yml` or `.yaml` and must have an extension. Use `<name>.yml.<n>.bak` or similar.
- Create `.abbrio/` and `.abbrio/backups/` once. Each folder creation costs a restart.
- Temp files for atomic writes need an extension such as `.tmp`. An atomic replace of a match file causes exactly one restart.
- A restart takes well under a second, but the worker comes back enabled, which matters for pause tracking (spike 8).
- A dropped picture restarts Espanso only the first time, when `images/` is created.

## Spike 11 — Hub index and package commands

**Index.**

- URL, as used by Espanso itself: `https://github.com/espanso/hub/releases/latest/download/package_index.json`. About 110 KB.
- Top level: `last_update` (Unix seconds) and `packages` (array). 243 entries for 197 distinct names: each published version is its own entry.
- Every entry has exactly these fields: `name`, `author`, `description`, `title`, `version`, `tags`, `archive_url`, `archive_sha256_url`.
- There is no featured flag, no per-package date, no README, no homepage and no download count.
- The archive is a zip with `_manifest.yml`, `package.yml` and `README.md`. The sha256 file holds the bare hex digest of the zip.
- The installed `_manifest.yml` has one more field than the index: `homepage`.
- Espanso keeps its own copy in `<runtime>/package_index_cache.json` as `{ "cached_at": …, "index": … }`. `--refresh-index` forces a new download.

**Consequences for the Packages view.**

- Featured is not in the index. The Hub website decides it from a fixed list of package names in its own source (`app/model/packages.ts` in `espanso/hub-frontend`, exported as `featuredPackages`). On 2026-11-11 the list was: `all-emojis`, `html-utils-package`, `lorem`, `spanish-accent`, `greek-letters-improved`, `math-symbols`, `medical-docs`, `shruggie`, `espanso-dice`.
- The app ships these nine names and can refresh them from that file. The `hub-frontend` repository has no license file, so take only the list of names from it, nothing else.
- Compute tag counts from the entries. Group entries by `name` and take the highest `version` as the current one.
- The README and the trigger preview both need the archive downloaded.
- "Update available" compares the installed `_manifest.yml` version with the index.
- A package's page on the Hub website is `https://hub.espanso.org/<name>` (checked 2026-11-14).
- An installed package's `_pkgsource.yml` is the word `hub` for a Hub package. For a git package it is a `!git` entry with `repo_url`, `repo_branch` and `use_native_git`.
- A failed install exits non-zero and prints the reason on standard output, for example `unable to install package: unable to find package 'x@latest' in the espanso hub`.
- `espanso package update <name>` moved a package installed with `--version 0.1.0` to the newest version in the index.

**Commands.** `install`, `uninstall`, `status`, `start`, `stop` and `restart` at the top level are hidden aliases; they are missing from `espanso --help` but work.

| Action | Command |
| --- | --- |
| Install | `espanso package install <name>` (alias `espanso install`), options `--version`, `--force`, `--refresh-index`, `--git <url>`, `--git-branch`, `--external`, `--use-native-git` |
| Uninstall | `espanso package uninstall <name>` (alias `espanso uninstall`) |
| Update | `espanso package update <name>`, or `all` |
| List | `espanso package list` |

- An installed package is a folder `match/packages/<name>/` with `_manifest.yml`, `_pkgsource.yml` (contains `hub` for Hub packages), `package.yml` and `README.md`.
- **Installing from git:** `espanso install <name> --git <url> --external` takes a repository whose root holds `package.yml` and `_manifest.yml`. A manifest with only `name`, `title`, `description`, `version` and `author` is accepted; `tags` and `homepage` are not needed. A local repository works as `file:///path`. The installed folder keeps the repository's `.git` folder, and `_pkgsource.yml` records the URL. The command needs no running daemon.
- **Reload:** Espanso restarts its worker by itself after both install and uninstall, and the package's matches appear in or disappear from `espanso match list` straight away. No `espanso restart` is needed.

## Other CLI findings

- `espanso match list --json` returns only `triggers`, `replace` and `label` per match. Regex matches appear with the pattern in `triggers`. It does not expose `word`, `propagate_case`, variables or the source file, so it cannot replace the app's own parser.
- `espanso match list` reads the config folder itself and works with no daemon running. It proves a file parses; it does not prove the daemon has reloaded. The reload is visible in the log as `configuration change detected, restarting worker process...`.
- `espanso match exec` takes `-t <trigger>` and repeatable `--arg name=value`.
- `espanso service` has `check`, `register`, `unregister`, `start`, `stop`, `restart`, `status`. `start` and `restart` accept `--unmanaged`.
- The Homebrew install registers a LaunchAgent, `com.federicoterzi.espanso.plist`.
- `espanso log` prints the log from the runtime folder.
- `espanso restart` and `espanso service start` go through the LaunchAgent. Run with `ESPANSO_CONFIG_DIR` and `ESPANSO_RUNTIME_DIR` set, `restart` stops the instance those variables point at, then starts the normal service on the normal config and reports `unable to start service: timed out`, because it waits for the instance in the other runtime folder. A throwaway instance is therefore restarted by stopping it and opening it again, never with `espanso restart`.
- The worker logs `monitoring the status of secure input` at start, so the log may also name the app holding Secure Input (to check in spike 12).
- Picture formats (checked 2026-11-17 from the 2.4.1 binary, not by expanding a match): the binary's only message about an `image_path` file is that it can't be found, and it uses `NSImage`'s `initWithContentsOfFile:` and the pasteboard's `writeObjects:`. `NSImage` reads SVG and PDF as well as bitmaps, and writing such an image to a pasteboard puts it there as TIFF. So SVG and PDF pictures are treated as working, and the app previews them.

## Spike 12 — who holds Secure Input

Espanso detects Secure Input itself and names the holder in its log:

```
[worker] [INFO] secure input has been acquired, preventing espanso from working correctly. Our guess is that this is caused by 'Terminal', but there are cases in which the detection is unreliable. Full path: /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
[worker] [INFO] secure input has been disabled
```

- The app can show the holder by following the log for these two lines, alongside its own `IsSecureEventInputEnabled()` check.
- Espanso itself calls the guess unreliable, so the UI should say "probably".
- Terminal's Secure Keyboard Entry only holds Secure Input while Terminal is frontmost; it was released five seconds later when another app came forward.
- The `ioreg` route (`kCGSSessionSecureInputPID`) is unverified: the key is absent when Secure Input is off, and it was already off again when queried.

## Dependencies checked

| Package | Version seen | License |
| --- | --- | --- |
| [Yams](https://github.com/jpsim/Yams) | 6.2.2 | MIT |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | — | MIT |
