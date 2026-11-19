# Abbrio — UX Design Spec

*Abbrio — the Mac app for Espanso.* A Typinator-style editor, menu-bar companion and Quick Search panel for the Espanso text expander.

Last updated: 2026-11-11

## Summary

Abbrio is a native Swift Mac app that looks and works like Typinator but stores everything as plain Espanso YAML. Espanso stays the engine that watches keystrokes and inserts text. Abbrio is the editor, the menu-bar companion and the Quick Search panel.

Four design decisions shape the rest of this spec:

| Decision | Choice | What it means for the build |
| --- | --- | --- |
| Quick Search | Own native panel | A Typinator-style floating panel in Swift. It pastes plain-text snippets itself and calls `espanso match exec` only for snippets that need Espanso (forms, scripts and other dynamic content). |
| Typinator-only features | Emulate plus sidecar | Prefix/suffix and case options compile into ordinary Espanso YAML. App-only settings live in a sidecar JSON the app owns. |
| Hand edits to YAML | Preserve them | The app edits only the match being changed. Comments and layout elsewhere in the file survive, and outside changes reload live. |
| Distribution | Developer ID, not sandboxed | Notarized DMG outside the App Store. The app reads the Espanso folder and runs the `espanso` CLI directly. |

The rest of this spec calls Abbrio "the app".

## Project, license and distribution

| Item | Decision |
| --- | --- |
| Language and tooling | Swift, built as an Xcode project. Releases are archived, signed and notarized from Xcode. |
| Source | Public GitHub repository. |
| License | MIT. |
| Distribution | Developer ID signed, notarized DMG. No App Sandbox, no Mac App Store. |

**What the MIT license requires of the code base.**

- **No Espanso source code in the repository.** Espanso is licensed under GPL-3.0. The app runs the user's installed `espanso` binary as a separate process and reads and writes its configuration files. It does not link against, copy from or bundle Espanso. Keeping that boundary is what lets the app's own code stay MIT; get this reviewed by someone qualified before the first release.
- **Dependencies must be MIT-compatible.** Check the license of every Swift package before adding it, and list third-party licenses in the About window.
- **Hub packages keep their own licenses.** The app downloads and installs them on the user's request and never redistributes them.
- **Fixtures and sample snippets** in the repository must be original or permissively licensed. Do not copy Typinator's built-in sets or its help text.

## Mockups

The visual reference for this spec is the set of 14 mockup boards in [`docs/mockups/`](docs/mockups/). Each section below names the boards that illustrate it.

| Board | Title | File | Size (pt) | Spec section |
| --- | --- | --- | --- | --- |
| 1 | Main window — light | [01-main-window-light.png](docs/mockups/01-main-window-light.png) | 1360 × 904 | Main window |
| 1 | Main window — dark | [01-main-window-dark.png](docs/mockups/01-main-window-dark.png) | 1360 × 904 | Main window |
| 2 | Details editor — three states | [02-details-editor.png](docs/mockups/02-details-editor.png) | 1540 × 900 | Abbreviation editor |
| 3 | Insert menu + Date/Time sheet | [03-insert-menu-date-time.png](docs/mockups/03-insert-menu-date-time.png) | 1180 × 900 | Dynamic content |
| 4 | Set Info sheet | [04-set-info.png](docs/mockups/04-set-info.png) | 880 × 840 | Sets |
| 5 | Apps window | [05-apps-window.png](docs/mockups/05-apps-window.png) | 1080 × 840 | Apps |
| 6 | Quick Search + Quick Define | [06-quick-search-quick-define.png](docs/mockups/06-quick-search-quick-define.png) | 1320 × 840 | Quick Search and Quick Define |
| 7 | Menu bar companion | [07-menu-bar.png](docs/mockups/07-menu-bar.png) | 1200 × 780 | Menu bar companion |
| 8 | Statistics | [08-statistics.png](docs/mockups/08-statistics.png) | 1100 × 780 | Statistics |
| 8 | Packages — Installed | [08-packages-installed.png](docs/mockups/08-packages-installed.png) | 1000 × 780 | Packages |
| 8 | Packages — Browse Hub | [08-packages-browse-hub.png](docs/mockups/08-packages-browse-hub.png) | 1000 × 780 | Packages |
| 8 | Package detail sheet | [08-package-detail.png](docs/mockups/08-package-detail.png) | 1000 × 780 | Packages |
| 8 | Install from Git URL | [08-install-from-git-url.png](docs/mockups/08-install-from-git-url.png) | 880 × 560 | Packages |
| 8 | Settings — General & Expansion | [08-settings-general-expansion.png](docs/mockups/08-settings-general-expansion.png) | 1440 × 780 | Settings |

Sizes are the board dimensions in points, not required window sizes. The PNG files are 2× exports, so their pixel dimensions are double these.

**How to read the mockups against this spec.**

- The mockups govern layout, spacing, visual hierarchy and wording of labels.
- This document governs behavior, the YAML that is written, and file handling.
- Where the two disagree, raise it as an issue instead of picking one silently.
- Both light and dark appearances are required. Only the main window has a dark board; every other screen follows the system appearance using standard macOS semantic colors.
- Screens with no board (Settings tabs other than General and Expansion, the regular-expression rule editor, the Import/Export sheets, error and empty states) follow the patterns of the nearest board and standard macOS conventions.

## Name and branding

| Item | Decision |
| --- | --- |
| Name | Abbrio, pronounced ah-BREE-oh |
| Tagline | Abbrio — the Mac app for Espanso |
| Meaning | A coined word: *abbreviation* + *brio*, Italian for liveliness or verve. It nods to Espanso's Italian name without copying it. |
| Domains | abbrio.app, abbrio.dev, getabbrio.com and abbrioapp.com had no registration on 2026-11-11 (registry RDAP lookup). abbrio.com is taken. None of them has been registered for the project yet. |

**Using the Espanso name.**

- "Espanso" appears only as a descriptor ("for Espanso"), never as part of the product name, the app icon or the bundle identifier.
- The About window and the website say that Abbrio is an independent app and is not made by or affiliated with the Espanso project.

**Before launch.**

- Register the domains that will be used (at minimum abbrio.app plus one .com variant that redirects to it).
- Run a trademark search on "Abbrio" (for example in the USPTO's search system). The name check so far covered domains and a web search only.
- Send a courtesy note to Espanso's maintainers about the app and its tagline.

## Scope, assumptions and constraints

The app targets macOS 14 Sonoma or later and Espanso 2.x, and it never captures keystrokes itself.

- **macOS target (assumption):** macOS 14+, universal binary. This version gives us mature `NavigationSplitView`, `MenuBarExtra` and `SMAppService` (launch at login). Older targets are possible but cost AppKit fallbacks.
- **UI stack:** SwiftUI for windows and forms. AppKit where SwiftUI is weak: the floating Quick Search `NSPanel` and an `NSTextView`-based expansion editor that shows variables as inline chips.
- **Espanso version:** v2.x is required; v2.4.1 was the current release when this spec was written. The app reads `espanso --version` and turns features on or off to match: statistics need 2.4.0, the date `tz` parameter needs 2.3.0, multi-select list separators need 2.4.0, and `.yaml` match files need 2.3.0.
- **Config folder:** Espanso's default on macOS is `~/Library/Application Support/espanso`. Users can move it to `~/.config/espanso`, so the app always asks `espanso path` first and falls back to the default.
- **Permissions:** Espanso keeps doing detection and injection while the user types. The app needs Accessibility permission for two things only: pasting the snippet chosen in Quick Search, and the optional "New Item from Selection" command, which has to read the selected text. It asks the first time either is used; everything else works without it.
- **Distribution:** Developer ID signed, notarized DMG, no App Sandbox.

**In scope for v1:** main window, set and abbreviation editing, Set Info, Apps, Quick Search, Quick Define, menu bar companion, Settings (`config/default.yml`), Statistics, and packages (installed list plus a Hub catalog to browse and install from).

**Out of scope for v1:** iOS, a sync service (users already sync the Espanso folder with a symlink), generated or assisted snippet authoring, sounds, and importing Typinator's own set files.

## Concept map: Typinator to Espanso

Every Typinator concept below maps to an Espanso file, field or CLI command, or to the app's sidecar. This table is the contract the rest of the spec builds on.

| Typinator concept | Espanso construct | App behavior |
| --- | --- | --- |
| Abbreviation set | One match file, `match/<slug>.yml` | One file is one set. The display name lives in the sidecar. |
| Set checkbox (active in all apps) | Files are auto-loaded unless the name starts with `_` | Unchecking renames the file to `_<slug>.yml` and rewrites every reference to it. |
| Regular expression set | A match file whose matches use `regex:` | Gets its own sidebar heading and a regex rule editor. |
| Abbreviation | `trigger:`, or a `triggers:` list | Prefix/suffix and case variants are compiled in when writing. |
| Expansion, plain text | `replace:` | Default expansion type. |
| Expansion, formatted text | `markdown:` or `html:` | v1 offers Markdown and HTML with a live preview. |
| Expansion, picture | `image_path:` | Dropped images are copied into `$CONFIG/images/`. |
| Description | `label:` | Shown in the list and in Quick Search. |
| Comments and custom search terms | `search_terms:` | Edited in the Advanced section. |
| Expand at word break | `word: true` |  |
| Expand on match | No word flag |  |
| Case affects expansion | `propagate_case: true`, plus optional `uppercase_style: capitalize_words` |  |
| Case must match | No flag | Espanso's default: triggers are case-sensitive. |
| Case does not matter | No direct field | Emulated as `triggers: [btw, Btw, BTW]`. |
| Input field `{{?Name}}` | Form field `[[name]]` | Built through the Insert menu. |
| Pop-up menu of alternatives | Form field `type: choice`, or `type: list` |  |
| Expand another abbreviation `{"abbr"}` | Variable `type: match` |  |
| Clipboard | Variable `type: clipboard` |  |
| Date and time | Variable `type: date` (`format`, `offset`, `locale`, `tz`) |  |
| Cursor position | Cursor hint `$|$` in the expansion text | Inserted from the Insert menu. Only one per match. |
| AppleScript or JavaScript | Variable `type: script` running `osascript`, or `type: shell` |  |
| Apps window | `config/<app>.yml` with a filter plus `extra_includes`, `extra_excludes` or `enable: false` |  |
| Quick Search | The app's own panel | Espanso's built-in search bar still exists. |
| Quick Define | Writes a new match into the chosen file |  |
| Statistics | `espanso stats --json` | Opt-in with `stats: enabled: true` (v2.4.0+). |
| Extensions | Espanso Hub packages in `match/packages/` | Packages view with Installed and Browse Hub tabs; installs run `espanso install`. |
| Pause Expansions | `espanso cmd disable` / `espanso cmd enable` |  |
| Settings | `config/default.yml` plus the app's own preferences |  |
| Set Info: prefix/suffix, default options, notes, Quick Search inclusion | Sidecar | Prefix/suffix also changes the written triggers. |
| Duplicate abbreviations: the top set wins and others get a yellow flag | Espanso shows a choice dialog when triggers collide | A badge explains the difference. |

## Main window

*Mockups: board 1, "Main window — light" and "Main window — dark".*

The main window copies Typinator's layout: sets on the left, the abbreviation list in the middle, the details editor on the right, and the main navigation in the toolbar.

An unchecked set is a file renamed with a leading underscore. Packages are locked. The footer names the file each edit is saved to.

**Toolbar (Typinator's main navigation).** Packages (Typinator's Extensions), Statistics, Apps, Settings, an Action menu and Help, plus a search field and an Espanso status pill (Running, Paused, Secure Input, Not running). The Action menu holds Import, Export, Reveal Config Folder, Open in External Editor and Restart Espanso.

**Sidebar (sets).**

- Three headings: Abbreviation Sets, Regular Expressions, and Packages. Packages are read-only and show a lock.
- Each row has a checkbox (active in All Other Applications), the set name, an item count, and a warning dot when the set has problems such as duplicate triggers or a YAML error.
- Footer buttons: `+` (New Abbreviation Set, New Regular Expression Set, Install Package), `−`, `ⓘ` Set Info, and the Apps button. Typinator puts the same buttons under its set list.
- Drag a set to reorder it. The order is for display only and is stored in the sidecar.
- Drag items onto a set to move them. Hold Option while dragging to copy, as in Typinator.
- Double-click a set to rename it. The context menu has Set Info, Duplicate, Reveal in Finder, Open in External Editor, and Export as Espanso Package.

**Abbreviation list (center).**

- Columns: Abbreviation, Expansion (first line), Description. All columns sort, and numbers sort numerically.
- Small glyphs mark each item's options: case mode, word break, dynamic content, form, picture, script, regex, and duplicate trigger.
- Search works like Typinator's. Several words must all appear, in any order, and a quoted phrase must match exactly. It looks at the abbreviation, expansion text, description and search terms. ⌘F focuses the search field.

**Keyboard shortcuts.** ⌘N new abbreviation, ⌥⌘N new set, ⌘D duplicate, ⌫ delete (with a confirmation), ⌘I Set Info, ⌘Z undo.

**Saving.** Changes are saved automatically about 500 ms after typing stops, or when a field loses focus. Espanso's `auto_restart` (on by default) reloads the file. A footer under the details pane shows the file path and "Saved · Espanso reloaded", or the error.

## Abbreviation editor (details pane)

*Mockups: board 2, "Details editor — three states".*

The details pane keeps Typinator's two option pop-ups, Case and Expand, and writes each choice as the Espanso flags in the table below. Espanso-only options go in a collapsed Advanced section.

From top to bottom:

1. **Abbreviation.** The bare abbreviation. The set's prefix and suffix appear as grey, non-editable text on either side.
2. **Options row.** A Case pop-up and an Expand pop-up (see the table).
3. **Description.** Written as `label:`.
4. **Expansion type.** A segmented control: Text, Markdown, HTML, Picture.
5. **Expansion editor.** Variables and the cursor show as inline chips. A `{…}` Insert button opens the dynamic-content menu, like Typinator's functions menu. Markdown and HTML get a split preview. Picture shows a drop well and the file name.
6. **Advanced (collapsed).**
   - Aliases: extra triggers, written to `triggers:`.
   - Search terms: written to `search_terms:`.
   - Insert using: Automatic, Keystrokes or Clipboard, written to `force_mode`.
   - Capitalize every word: `uppercase_style: capitalize_words`. Only active with "Case affects expansion".
   - Markdown without a new paragraph: `paragraph: true`.
7. **YAML tab.** Shows the match exactly as written in the file. "Edit as YAML" lets you change anything the form can't, such as anchors or unknown keys, and validates the YAML before saving.

| Control | Choice | YAML written |
| --- | --- | --- |
| Case | Case must match | Nothing (Espanso's default) |
| Case | Case does not matter | `triggers:` with lowercase, Capitalized and UPPERCASE variants |
| Case | Case affects expansion | `propagate_case: true` |
| Expand | At word break | `word: true` |
| Expand | On match | Nothing |
| Expand (advanced) | At word start only | `left_word: true` |
| Expand (advanced) | At word end only | `right_word: true` |
| Insert using | Automatic / Keystrokes / Clipboard | Nothing / `force_mode: keys` / `force_mode: clipboard` |

**"Case does not matter" emulation.** For `btw`, the app writes `triggers: [btw, Btw, BTW]` and records `caseMode: insensitive` in the sidecar, so the UI still shows one abbreviation. Mixed casings such as `bTw` will not expand, which differs from Typinator. This mode can't be combined with "Case affects expansion".

**"Case affects expansion" match.** Typinator's three rules (all caps, first capital, lowercase) are the same behavior Espanso documents for `propagate_case`: `alh`, `Alh` and `ALH` become "although", "Although" and "ALTHOUGH".

**Validation, shown inline.**

- An empty abbreviation is refused. Espanso 2.3.0+ skips empty triggers with a warning.
- A second cursor marker gets a warning, because Espanso only honors one.
- A trigger that is also used in another active set gets a badge: "Espanso will ask which one to use."
- Variable names may contain only letters, numbers and underscores, as Espanso requires.

## Dynamic content: the Insert menu

*Mockups: board 3, "Insert menu + Date/Time sheet".*

The `{…}` Insert menu offers Typinator's built-in functions and writes each one as an Espanso variable or form. The editor shows a chip, and the file stores `{{name}}` plus a `vars:` entry. Variable names are generated automatically and can be renamed.

| Menu item | Typinator equivalent | Espanso output | Editor UI |
| --- | --- | --- | --- |
| Cursor Position | Cursor marker | The cursor hint `$|$` at that spot | Chip; a second one is blocked |
| Clipboard | `{clip}` | `type: clipboard` | Chip |
| Date/Time… | Date/Time tools | `type: date` with `format`, `offset` in seconds, `locale` (BCP47), `tz` (IANA, v2.3.0+) | Sheet with format presets, a strftime builder, offset entered as days and hours, and a live preview |
| Input Field… | `{{?Name}}` with an optional default | Form field `[[name]]` with `default` and `multiline` | Sheet: label, default, single or multi-line |
| Pop-up Menu… | Alternatives | Form field `type: choice`; multi-select uses `type: list` with `separator` (v2.4.0+) | Sheet: values list, default |
| Insert Abbreviation… | `{"abbr"}` | `type: match` with `trigger` | Picker of existing triggers |
| Script… | AppleScript / JavaScript | `type: script` running `osascript` on a file in `$CONFIG/scripts/`, written as `%CONFIG%/scripts/<file>`, or `type: shell` with `cmd` | Sheet: language, code editor, Test button |
| Choice Dialog… (Espanso extra) | None | `type: choice` with `values` | Sheet: values with optional label and id |
| Random Text… (Espanso extra) | None | `type: random` with `choices` | Sheet: list of alternatives |
| Shell Command… (Espanso extra) | None | `type: shell` with `cmd` | Sheet: command, Test button |
| Global Variables… (Espanso extra) | Variables | `global_vars` in the set's file | Opens Set Info, where the list is edited with the same sheets. A global variable is used by typing `{{name}}` |

**Forms look like Typinator's input dialog.** Typinator's dialog shows labelled fields, not the whole expansion. So when a match gains its first input field or pop-up, the app writes Espanso's verbose form syntax. The `layout` holds only the labelled fields, and `replace` uses `{{form1.field}}`:

```yaml
- trigger: ";dear"
  replace: "Dear {{form1.first_name}} {{form1.last_name}},"
  vars:
    - name: form1
      type: form
      params:
        layout: "First name: [[first_name]]\nLast name: [[last_name]]"
        fields:
          first_name:
            default: "Thomas"
```

**Rules for dynamic content.**

- **Chips follow the text.** Deleting a chip removes its `vars:` entry, unless another variable uses it. Undoing the deletion in the text box brings the entry back. Only the entry that changed is rewritten; the others keep their lines, comments included.
- **The short form syntax is kept.** A match already written with `form:` (and `form_fields:`) stays that way. Its fields show as chips and can be edited, renamed, added and removed without converting it. It is rewritten in the verbose syntax only when an edit needs something the short one can't hold: another kind of variable, or a change to Markdown or HTML.
- **A form without fields is plain text.** Removing the last field removes the form variable and leaves `replace:`. For the short syntax, `form:` becomes `replace:`.
- **Scripts.** A script is kept as `scripts/<variable name>.applescript` or `.js` in the config folder and run with `osascript`. A file that exists is never replaced by a new script; the new one gets a numbered name. Deleting a chip leaves the file, because another match may use it. Test runs the script or command on this Mac. Under the Test controls, the Script and Shell Command sheets show: "Test runs this code with your permissions and can change files or access the network."
- **Type changes.** Between Text, Markdown and HTML the content stays exactly as it is and only the key changes (`replace`, `markdown`, `html`); nothing is converted. Switching to Picture asks first when there is content, and Cancel leaves the match as it was. The content is put aside while the item stays selected, so switching back restores it. Only what belongs to the chosen type is saved, and one Undo restores the whole previous match.
- **Pictures.** A chosen or dropped picture is copied into `images/` in the config folder, under a safe name nothing else there uses, and the match is saved only after the copy is complete, as `image_path: "$CONFIG/images/<file>"`. The original is left untouched; later changes to it don't reach the copy. "Reference original file" writes the file's own path instead and copies nothing. An existing `image_path` is kept as it is until another picture is chosen. The app never deletes a picture.
- **Previews.** The Markdown and HTML previews and the date preview are drawn by the app and can differ slightly from Espanso's output. The HTML preview runs no scripts and loads nothing from the network.

**Typinator features with no Insert-menu entry:** calculations, keystrokes (Tab, Return, arrows), delay, and the suppress markers. See Gaps.

## Sets: Set Info and regular-expression sets

*Mockups: board 4, "Set Info sheet". The regular-expression rule editor has no board.*

The Set Info sheet has the same fields as Typinator's (open it with ⓘ or ⌘I). Most fields live only in the sidecar; prefix/suffix and global variables also change the YAML.

| Field | Stored in | Effect on the YAML |
| --- | --- | --- |
| Name | Sidecar | Sets the file name slug when the set is created. Renaming can also rename the file; the app asks first. |
| Prefix / Suffix | Sidecar | Added to every trigger in the file. Changing it rewrites all triggers in one save. |
| Default Options (Case, Expand) | Sidecar | Applied to new items only, including items made with Quick Define. |
| Count replacements as (Expansion or Correction) | Sidecar | Groups the set's numbers in Statistics. |
| Include in Quick Search (abbreviations, expansions) | Sidecar | Affects only the app's own Quick Search panel. |
| Global variables | `global_vars:` in the set's file | Available to every match in the set. |
| Notes | Sidecar | None. |

Typinator's per-set feedback sound is not offered, because Espanso has no hook for it.

**Prefix and suffix rules.**

- If every trigger in the file already starts with the prefix being entered (or ends with the suffix), the app asks whether to take it as the set's existing one, which changes nothing in the file, or to add it again.
- If the set holds items the form can't rewrite (see "Constructs the form can't round-trip"), the change is refused and the sheet names those items. Nothing is rewritten in part. Regular-expression rules are skipped; a prefix has no meaning for them.
- An item whose triggers don't carry the set's prefix and suffix, for example after a hand edit, is shown and saved as written.
- Until the Insert menu exists, the global variables table is read-only.

**Creating and deleting sets.**

- `+` creates `match/<slug>.yml` containing `matches: []`.
- Deleting a set asks for confirmation (Typinator warns too). The app moves the file to the Trash so it can be recovered, and removes references to it from `config/*.yml`.
- If a file can't be parsed, its set still appears with an error badge. Only the YAML view can be used until the error is fixed.

**Regular-expression sets.** Each rule is a match with `regex:` instead of `trigger:`. The rule editor has:

- A Pattern field in Rust regex syntax. Named groups must be written `(?P<name>…)`, which Espanso requires.
- An Expansion field that offers a chip for each named group, written as `{{name}}`.
- A live tester: type sample text and see whether it matches and what the output is.
- A converter for Typinator habits. Typinator uses ICU regex and `$1`-style references, and the converter offers to turn numbered groups into named ones.
- Warnings for ICU-only syntax that Rust's regex engine doesn't support, such as look-around and back-references. Also a warning when a pattern can run past `max_regex_buffer_size`, Espanso's limit on regex match length (default 30).

How these work:

- **New Regular Expression Set** creates an empty match file like any other set. An empty file can't say what it is for, so the sidecar remembers it (`holdsRegularExpressions`); once the file has matches, they decide: a set is a regular expression set when all its matches use `regex:`.
- **Group chips.** A row of buttons above the expansion, one per named group. A `{{name}}` that names a group is drawn as a chip.
- **Tester.** The sample is fed in one character at a time against the last `max_regex_buffer_size` characters, and the rule fires at the first match, as it would while typing. It shows the matched text, each group's value and the output. It uses the system's regular expression engine after respelling `(?P<name>` and says so; when the pattern holds something Espanso refuses, a match is reported with that caveat. Sample text is kept per item until the app quits.
- **Converter.** Offered when the expansion refers to groups as `$1`, `${1}` or `${name}`, or the pattern spells a name `(?<name>…)`. It names the numbered groups that are referred to (`group1`, `group2`, …), respells plain names, and rewrites the references as `{{…}}`, in one save.
- **Warnings.** Look-ahead, look-behind, back-references, atomic groups, possessive quantifiers, `(?<name>…)`, two groups with one name, and parentheses that don't pair up. Espanso skips a rule it can't compile, so these are shown as errors but do not stop the save.
- **Length.** The editor works out the shortest and longest match a pattern allows. A pattern that needs more characters than the limit is flagged as never expanding; one that can exceed it gets a note.

Typinator's help notes that regex sets match inside words. Espanso regex triggers behave the same way, so the UI shows the same caution about rules that interfere with normal typing.

## Apps: per-application set activation

*Mockups: board 5, "Apps window".*

The Apps window looks like Typinator's: a list of apps on the left and set checkboxes on the right. The app compiles that grid into Espanso's underscore file names plus one `config/<app>.yml` per listed app.

**UI.**

- At first the list holds one row, All Applications.
- Add an app by dragging it from the Finder, picking a running app from `+`, or searching Spotlight (Typinator 10.1 added Spotlight search here). Once an app is added, the first row is renamed All Other Applications, as in Typinator.
- Select an app to see a checkbox per set and per package. A "Turn all off" toggle disables expansion in that app entirely.
- A collapsed Advanced panel per app holds Espanso-only options that work per app: `backend`, `inject_delay`, `key_delay`, `paste_shortcut`, `clipboard_threshold`.

**Compile rules.**

| Set on in All Other Applications | Set on in app A | What the app writes |
| --- | --- | --- |
| Yes | Yes | Nothing extra |
| Yes | No | In A's config: `extra_excludes: ["../match/<slug>.yml"]` |
| No | Yes | File renamed to `_<slug>.yml`; in A's config: `extra_includes: ["../match/_<slug>.yml"]` |
| No | No | File renamed to `_<slug>.yml` |
| Every set off in A | — | In A's config: `enable: false` |
| A package off in A | — | In A's config: `extra_excludes: ["../match/packages/<name>/*"]` |

An example of a generated app config. On macOS `filter_class` matches the bundle identifier and `filter_exec` the path of the app bundle; the app writes `filter_class` so the rule survives the app being moved:

```yaml
# config/com.apple.mail.yml, written by Abbrio
filter_class: "^com\\.apple\\.mail$"
extra_includes:
  - "../match/_email-signatures.yml"
extra_excludes:
  - "../match/autocorrect.yml"
```

**Rules the compiler must respect.**

- **One app config at a time.** Espanso always applies `default.yml` but only one app-specific config. When several filters match, the file that sorts first alphanumerically wins. So before creating a file, the app tests every existing `config/*.yml` filter against the app it is adding. If a hand-written config already matches, the app edits that file instead of adding a competing one. Overlaps get a warning in the Apps window.
- **Filters are regexes.** Paths and bundle IDs are escaped (dots, parentheses) before writing.
- **Inheritance.** An app config extends `default.yml` and overrides only the options it sets. The Advanced panel shows inherited values greyed out.
- **Lists replace, they don't add.** An `extra_includes` or `extra_excludes` list in an app config replaces the same list in `default.yml`. When `default.yml` has such a list and the app writes one for an app for the first time, it starts from the entries in `default.yml`, so the other sets stay as they were in that app. A list that ends up equal to the one in `default.yml` is removed from the app config again, and a list that must be empty is written as `[]`.
- **Renames stay consistent.** Turning a set's global checkbox on or off renames the file, and every `includes`/`excludes` reference in `config/` is rewritten in the same save.
- **Turn all off keeps the grid.** Only the "Turn all off" toggle writes `enable: false`. The lists in the file stay, so switching it back restores the choices. Unchecking every set by hand writes excludes instead.
- **Adding and removing.** Adding an application writes its config file at once, holding only the filter, so the list is read back from the files alone. Removing one moves its config file to the Trash after a confirmation, a hand-written file included.
- **Packages.** A package can be switched off per application. Switching one off for all other applications is not offered yet.
- **Detect helper.** A "Show what Espanso sees" link explains how to type `#detect#` in the target app; Espanso then shows the window title, executable and class it detected.

## Quick Search and Quick Define

*Mockups: board 6, "Quick Search + Quick Define".*

Quick Search is the app's own floating panel, opened by a global hotkey. It pastes the chosen snippet into the frontmost app itself. Espanso's `match exec` cannot be used for this in general, because it deletes as many characters before the cursor as the trigger is long (see `docs/espanso-facts.md`, spike 4).

**Quick Search behavior.**

1. The global hotkey defaults to ⌃⌘S, Typinator's default. It is configurable in Settings.
2. A non-activating `NSPanel` appears near the top centre of the active screen, below the menu bar and the notch, with a search field and a results list.
3. Each result shows the abbreviation, description, a one-line expansion preview and the set name. It searches trigger, `label`, `search_terms` and expansion text, using each set's Quick Search inclusion settings.
4. Several words must all appear, and quotes force an exact phrase. A single `.` lists recently used items, as in Typinator.
5. **Return inserts.** The app closes the panel, waits about 200 ms (configurable, like Espanso's `post_search_delay`) for the target window to become key again, and for the modifier keys to be released, then inserts:
   - **Plain-text snippets** (a `replace:` with no variables or forms): the app puts the text on the clipboard, sends ⌘V, and restores the previous clipboard contents afterwards. A cursor marker `$|$` is removed from the text and the cursor is moved back to its place.
   - **Everything else** (variables, forms, scripts, Markdown, HTML, pictures): the app pastes the snippet's trigger and then runs `espanso match exec -t <trigger>`, so the characters Espanso deletes are the ones just pasted. Matches with forms show Espanso's form as usual. The clipboard is put back before `match exec` runs, so a clipboard variable sees what the user had copied. The technique was checked at the start of Phase 5 (see `docs/espanso-facts.md`).
   - Only one insertion runs at a time; a second Return is ignored until the first has finished.
6. **⌘Return or ⌘double-click** opens the item in the main window editor, like Typinator's shortcut for editing from Quick Search.
7. Esc closes the panel. If Espanso isn't running, the panel shows the error inline with a Start Espanso button.
8. Regex-only rules have no trigger to execute, so they appear dimmed and can only be opened, not inserted.

**Rules for Quick Search.**

- The tag in the panel's footer says how the selected item is inserted: `espanso match exec -t <trigger>` for an item that needs Espanso, "pastes the text" for plain text, "open only" for a regex rule. Board 6 shows the command for a plain-text item; the tag follows this spec.
- Only sets that are switched on take part. A set's Quick Search settings decide whether its abbreviations and its expansions are searched; descriptions and search terms are searched whenever the set takes part, and a set with both settings off is left out.
- Abbreviations that equal what was typed come first, then those that start with it, then those that contain it, then everything else.
- Nothing typed lists nothing. The list is capped at 50 results.
- A snippet with several triggers, such as one saved with "Case does not matter", is one row and is inserted through its first trigger.
- Plain text is pasted even while Espanso isn't running. An item that needs Espanso is refused then, before anything is pasted.
- Before inserting, the app waits up to three seconds for the modifier keys to be released, and inserts nothing if they stay down.
- The clipboard is put back only if nothing else was copied in the meantime. The text the app puts on the clipboard is marked as transient, so clipboard managers that follow that convention don't record it.
- Without the Accessibility permission nothing is sent. The panel stays open, says so, and macOS shows its permission request.
- If Espanso refuses an expansion, the panel reopens with the reason. The pasted trigger is left in the text.
- A double-click on a row inserts it. A click outside the panel closes it.

**Recently used list.** Recents come from Espanso's statistics database when statistics are on (see Statistics), which covers typed expansions as well as Quick Search insertions made through `match exec`. Snippets the app pastes itself are not seen by Espanso, so the app also keeps its own list of those and merges the two by time. Until the Statistics view exists, the list holds only the app's own record of Quick Search insertions (the last 50, kept in the app's preferences); the merge with the statistics database arrives with Statistics.

**Espanso's own search bar.** Espanso's search bar stays available (default ⌥Space). Settings offers to switch it off with `search_shortcut: off`, so there is only one search UI.

**Quick Define (Typinator's "New Item from Selection / Clipboard").**

- Two menu-bar commands, each with an optional global hotkey:
  - New Item from Clipboard… needs no permissions.
  - New Item from Selection… needs Accessibility permission to read the selected text, through `AXSelectedText` or a simulated ⌘C. The app asks for the permission the first time this command is used.
- A compact window with Abbreviation, Expansion (pre-filled), Description, and a Set picker that remembers the last set used (Typinator 10.2 does the same).
- The chosen set's Default Options are applied, and its prefix and suffix are added to the abbreviation. Saving writes straight to that set's YAML file and shows the new item in the main window.
- The first time, the window starts with the set selected in the main window. Packages, regular-expression sets and files that can't be read are not offered.
- Until Settings exists, the two commands have no global hotkey.

## Menu bar companion

*Mockups: board 7, "Menu bar companion".*

A `MenuBarExtra` icon plays the role of Typinator's "T" menu: it shows Espanso's state at a glance and holds the quick commands. Quitting the app never stops Espanso. Closing the main window does not quit the app: it keeps running with its menu bar icon and stays in the Dock until Quit is chosen.

**Icon states.**

| State | Icon | How the app knows |
| --- | --- | --- |
| Expanding | Normal | `espanso status` reports the daemon running |
| Paused | Pause badge | The app ran `espanso cmd disable`, or Espanso's log shows `toggled enabled state, is_enabled = false`. `espanso status` does not report a pause. A worker restart resets Espanso to enabled. |
| Secure Input on | Two-dot badge, like Typinator's | `IsSecureEventInputEnabled()`; the app holding it is taken from Espanso's log, which names its best guess, and shown as "probably" |
| Espanso not running | Warning badge | `espanso status` fails, or the binary is missing |

**Menu.**

- Quick Search… (shows the hotkey)
- New Item from Clipboard…
- New Item from Selection…
- Pause Expansions / Resume Expansions
- Open Main Window
- Restart Espanso
- Settings…
- Quit (the app only)

The first line of the menu shows the state and Espanso's version, with a colored dot. When Espanso isn't running, a Start Espanso item follows it, which runs `espanso service start`. If a command sent to Espanso fails, the reason is shown under the first line until a command succeeds. Settings… is shown disabled until Settings exists. The app asks Espanso for its state every three seconds.

Espanso shows its own menu bar icon too. Settings offers to hide it with `show_icon: false`, so only one icon remains.

## Statistics, Packages, Settings, Import/Export

These four toolbar destinations wrap existing Espanso features: `espanso stats`, the Hub package manager and `config/default.yml`. Only Import/Export is new logic in the app.

### Statistics

*Mockups: board 8, "Statistics".*

- Espanso has tracked trigger usage since v2.4.0. It is off by default and turned on with `stats: enabled: true` in `config/default.yml`. If it is off, the view shows a "Turn on statistics" button that writes that key.
- The app reads `$CONFIG/stats.db` directly and read-only. It is an SQLite database in WAL mode with one row per expansion: the typed text and a UTC timestamp. Reading it gives what the CLI's JSON does not: time series, recents and exact local-day boundaries. The CLI is still used for `stats clear` and `stats prune`, and `espanso stats --json` is the fallback if the database cannot be read or its layout is not the one recorded in `docs/espanso-facts.md`.
- Espanso records what was typed, so the app folds case variants into their match and attributes regex hits by running the set's patterns against the recorded text.
- Table columns: Trigger, Set, Counted as, Count, Share. The ten most used triggers are listed and the rest are summed up in one "other triggers" line, which shows them all when clicked. The Share bars are drawn against the most used trigger; the percentage is of all expansions in the period. Typed text that no item explains, such as an item deleted since, is listed as "Not in any set". A period picker offers Today, Last 7 days, Last 30 days, Last 365 days and All time, matching Espanso's `today`, `week`, `month`, `year` and `all`, except that Today uses the local day (Espanso's `today` starts at midnight UTC).
- Summary cards show expansions, corrections (split by each set's "Count replacements as") and estimated characters saved.
  - Characters saved = (expansion length − trigger length) × count, never less than zero for an item. The length is that of the expansion as written, without the cursor marker; a picture counts as zero.
  - Time saved = characters saved ÷ a typing speed set in Settings. It is always labelled as an estimate, like Typinator 10.1's time-saved figure.
- The database is opened where it is, read-only, and as an unchanging file when Espanso has closed it (see `docs/espanso-facts.md`).
- Quick Search's list of recent items is the app's own history merged with the last use of each trigger in the database, newest first, one entry per item.
- Buttons, each behind a confirmation: Clear runs `espanso stats clear`. "Prune older than N days" runs `espanso stats prune --days N`.

### Packages (Typinator's Extensions)

*Mockups: board 8, "Packages — Installed", "Packages — Browse Hub", "Package detail sheet" and "Install from Git URL".*

The Packages view has two tabs, Installed and Browse Hub, so packages can be found and installed without leaving the app, the way Typinator's Extensions work.

**Installed tab.**

- The list is read from `match/packages/*/_manifest.yml`: name, title, description, version, author, tags.
- Each row shows title, identifier and version. An Update badge appears when the Hub catalog has a newer version.
- Package items are read-only, because updates overwrite them. "Copy to My Sets" duplicates an item into an editable set.
- Turning a package on or off per app happens in the Apps window.

**Browse Hub tab** (mirrors [hub.espanso.org/search](https://hub.espanso.org/search)).

- A search field covers title, identifier, description, author and tags.
- Tag chips show package counts, as the Hub page does (for example languages, symbols, utility, math). A Featured toggle filters to featured packages.
- Each result row shows title, identifier, author, a one-line description and tags. A badge shows Featured, Installed or Update available.
- Results sort with Featured first, then by title.
- Selecting a row opens the package detail sheet.

**Package detail sheet.**

- Title, identifier, author, version, tags, and a link to the package's Hub page.
- The package README, rendered as Markdown.
- Optional snippets preview: the app downloads the package archive from the index's URL and lists its triggers before you install. Triggers that already exist in your sets get a warning, because Espanso would show its choice dialog for them.
- Buttons: Install, or Update and Uninstall when installed. "Install Specific Version…" adds `--version`.

**Installing.**

- Install runs `espanso package install <name>`, and a specific version adds `--version <v>`. Uninstall runs `espanso package uninstall <name>` and Update runs `espanso package update <name>`.
- Progress shows inline in the row and the sheet. On failure, Espanso's own output is shown.
- When it finishes, the Installed tab refreshes and the package appears in the sidebar under Packages. Espanso reloads by itself after an install or uninstall, so no restart is needed.

**Catalog data.**

- **Source:** the Hub's `package_index.json` at `https://github.com/espanso/hub/releases/latest/download/package_index.json`. Each entry has `name`, `author`, `description`, `title`, `version`, `tags`, `archive_url` and `archive_sha256_url`, with one entry per published version. Package archives with SHA256 checksums are published to GitHub Releases under espanso/hub.
- **Not in the index:** dates, the README and the homepage. The README shown in the detail sheet comes from the downloaded archive.
- **Featured:** the index has no featured flag. The Hub website marks a fixed list of package names as featured in its own source (nine names when checked; see `docs/espanso-facts.md`). The app ships that list of names and refreshes it from the Hub website's repository when it refreshes the index; if the refresh fails or the file has changed shape, the shipped list is used.
- **Caching:** the app keeps a copy in its Caches folder. It refreshes when the tab opens and the copy is older than 24 hours, and a Refresh button forces it.
- **Offline:** if the index can't be fetched, the tab shows the cached copy with its date, or a button that opens hub.espanso.org.
- **Tag counts:** computed from the package tags, counting each package name once.

**How the Packages view works.**

- The window opens from the toolbar. "Install Package…" in the sidebar `+` menu opens it on Browse Hub.
- Installed: the Update button is on when the catalog lists a newer version of a Hub package; for a package installed from git it is always on, because only Espanso can tell. Uninstall asks first.
- "Copy to My Sets…" is a menu of the user's sets plus "New Set…". It copies the selected items, or every item when none is selected.
- Browse Hub shows the four most used tags as chips and the rest under "More…". A row's button reads Install, Installed or Update. Clicking the row opens the detail sheet.
- The detail sheet downloads the archive when it opens and checks it against the published SHA256. That shows the download is intact, not who made it: the checksum comes from the same place as the archive. Downloads come only from GitHub (`github.com` and the `githubusercontent.com` hosts it serves files from) over https, redirects included, and stop at 32 MB. The archive is not unpacked: its list of files is read with `zipinfo`, and an archive with more than 2,000 entries, more than 32 MB declared in all, links, encrypted entries, duplicate names or names that leave the archive is refused. Only the README and the match files are then read with `unzip -p`, at most 4 MB each, within 30 seconds in all. The README is rendered with the system's Markdown parser; only web links stay clickable.
- Match files larger than 16 MB, files that are not regular files, and files whose YAML aliases expand to more than two million nodes are shown as unreadable instead of being parsed.
- Copy to My Sets says so when the items being copied run commands or scripts.
- "Install Specific Version…" lists the versions in the catalog and appears when there is more than one.
- "View on Hub" opens `https://hub.espanso.org/<name>`.
- Package names and repository addresses are checked before they are passed to `espanso`, so that neither can be read as an option.
- The board's command tags and spike notes are not shown, except the "Command the app runs" box in the git sheet and the `_manifest.yml` and `extra_excludes` tags.

**Install from Git URL…** (in the Action menu and the sidebar `+` menu).

- A sheet asks for the package name and repository URL, then runs `espanso install <name> --git <url> --external`. This works for GitHub and GitLab repositories, and for other git hosts through `git clone`.
- A warning explains that external packages haven't been reviewed by the Espanso team, unlike Hub packages.

### Settings

*Mockups: board 8, "Settings — General & Expansion". The other tabs have no board and follow the same form layout.*

App-only preferences are stored in `UserDefaults`. Espanso options are written to `config/default.yml`. An option the user never changed is not written, so Espanso's default applies. "Reset to default" removes the key, and hovering a control shows its YAML key.

| Tab | Options |
| --- | --- |
| General (app) | Launch at login (`SMAppService`), show window at launch, menu bar icon, Quick Search and Quick Define hotkeys, typing speed for estimates, espanso binary path override, config folder (shown read-only, from `espanso path`), and whether renaming a set also renames its file (ask each time, always, or never; until this setting exists the app asks and keeps the file name by default), and whether abbreviations expand in Abbrio's own windows. They do not by default: at launch, when no config file applies to Abbrio, the app writes `config/com.zardozgroup.abbrio.yml` with a `filter_class` for its bundle identifier and `enable: false`, so a trigger or a regex sample typed into one of its fields stays as typed. Switching the setting on removes the `enable` line and keeps the file, so the app does not write it again |
| Expansion | `backend` (auto, inject, clipboard), `clipboard_threshold`, `preserve_clipboard`, `undo_backspace`, `backspace_limit`, `word_separators` (token list editor), `toggle_key` (OFF by default), `auto_restart` |
| Espanso UI | `search_shortcut`, `search_trigger`, `show_icon`, `show_notifications`, `max_form_width`, `max_form_height` |
| Timing (advanced) | `inject_delay`, `key_delay`, `pre_paste_delay`, `restore_clipboard_delay`, `paste_shortcut`, `post_form_delay`, `post_search_delay`, `max_regex_buffer_size` |
| Statistics | `stats: enabled` |

### Import / Export (Action menu)

*No board.*

- **Import CSV/TSV** with abbreviation, expansion and optional description columns into a new set.
- **Export a set as an Espanso package:** a folder with `package.yml`, `_manifest.yml` and `README.md`. This is the counterpart of Typinator's "Publish Sets".
- **Export a set as CSV.**

How these work:

- Import reads comma- or tab-separated text. Tabs are assumed when each of the first rows has one. Fields may be quoted, and a quoted field may hold the separator, doubled quotes and line breaks. A first row whose first two fields read like column names (such as "abbreviation" and "expansion") is taken as a header; the sheet has a checkbox to overrule that. Rows without an abbreviation or an expansion are left out and counted. Files that are not UTF-8 are read as UTF-16 or Windows Latin 1.
- The sheet shows the rows and asks for the new set's name. Every row becomes a plain-text item, with the description as its `label`. The set's file is written in one go.
- CSV export writes a header row and one row per abbreviation, so an item with aliases takes several rows. Pictures, forms and regular-expression rules are left out and counted. Dynamic content is written as it stands in the file, without its variables.
- Package export asks for name (lowercase letters, digits and hyphens), title, author, version (three numbers) and description, then for a folder. It creates `<name>/` there and never replaces an existing one. `package.yml` is the set's file byte for byte, `_manifest.yml` holds the five fields, and `README.md` lists the items. Files the set refers to under `$CONFIG` are not copied; the sheet says so.
- A package folder installs with `espanso install <name> --git <url> --external` once it is the root of a git repository.
- Both exports are in the Action menu for the selected set and in a set's context menu. Installed packages can be exported as CSV but not as packages.

- **Import Typinator sets** is planned for v2, once Typinator's export format has been looked into.

## Data and file strategy

The YAML files are the source of truth. The app edits them surgically, keeps its own metadata in a sidecar, and talks to the running daemon only through the `espanso` CLI.

```
┌──────────────┐  reads / surgical writes   ┌───────────────────────────┐
│              │ ─────────────────────────▶ │ Espanso config folder     │
│    Abbrio    │ ◀───────────────────────── │  match/*.yml              │
│              │        FSEvents            │  config/*.yml             │
│              │                            │  .abbrio/ (sidecar,       │
│              │                            │            backups)       │
└──────┬───────┘                            └─────────────┬─────────────┘
       │ espanso CLI                                      │ auto_restart
       │ (status, match exec, stats, install…)            │ reload
       ▼                                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Espanso daemon: detects triggers and types into other apps           │
└──────────────────────────────────────────────────────────────────────┘
```

The app never talks to the daemon directly. It changes files, which Espanso reloads, it runs CLI commands for status, dynamic insertion and package management, and it reads Espanso's statistics database read-only.

### Finding Espanso

- **Binary:** the user's override from Settings, then `PATH`, `/opt/homebrew/bin/espanso`, `/usr/local/bin/espanso`, and finally the binary inside `Espanso.app`.
- **Config folder:** the output of `espanso path`. If that fails, `~/Library/Application Support/espanso`, then `~/.config/espanso`.
- **Version:** `espanso --version` decides which features are shown (see Scope).

### Reading

- Parse every `match/**/*.yml` and `*.yaml` file, including `_`-prefixed ones, which appear as sets that are off globally. Also parse `config/*.yml`.
- The parser must report the source range (line and column, start and end) of each match node, because surgical writes depend on it. Yams `Node` marks give the start of each match; the end is derived from the next match's start (see `docs/espanso-facts.md`).

### Writing, with hand edits preserved

- **Edit:** replace only the byte range of the changed match mapping. Re-emit that one match in a canonical style: block mappings, quotes only when needed, `|` literal blocks for multi-line text, and the file's existing indentation.
- **Add:** append at the end of the `matches:` sequence.
- **Delete:** remove the match's range, along with any comment lines directly above it.
- **Keep everything else byte for byte:** comments, ordering, blank lines, and other matches.
- **Constructs the form can't round-trip** (anchors, aliases, merge keys, flow-style matches, unknown keys) mark the item "Advanced YAML". The form shows those parts read-only, the YAML tab stays editable, and unknown keys are kept verbatim.
- **Safety:** re-parse the full new text before writing. Write atomically (temp file, then rename). Keep the last 20 versions of each file in `$CONFIG/.abbrio/backups/`. The temporary file gets a new random name each time and is created exclusively, so nothing already at that path is written through. A match file that is a symbolic link is saved to the file it points at and the link stays; a link that leads nowhere, or to something other than a regular file, is refused. Paths the app builds from names in YAML (script files, for example) may not leave the config folder.
- **File names Espanso reacts to:** Espanso restarts its worker for any path in the config folder that ends in `.yml` or `.yaml` or has no extension, hidden folders included. Backups are therefore named `<file>.<n>.bak`, temp files end in `.tmp`, and the `.abbrio/` folders are created once.
- **Confirm:** after a write, Espanso's `auto_restart` reloads. The app checks `espanso match list --json` to confirm the file parses and the trigger is present, and Espanso's log to confirm the reload; otherwise it shows the error.

### Outside changes

- FSEvents watches the config folder, and a changed file is reloaded.
- If the user is editing a match that changed on disk, a banner offers Keep Mine or Load from Disk.

### Sidecar

- **Location:** `$CONFIG/.abbrio/metadata.json`. It sits inside the Espanso folder so it travels with a synced config. It is outside `match/` and `config/` so Espanso never loads it. Writing the `.json` file does not trigger a reload.
- **Per set** (keyed by path relative to `match/`): display name, order, type, prefix, suffix, default options, count-as, Quick Search flags, notes.
- **Per match** (keyed by set path plus the bare abbreviation): case mode and bare trigger.
- **Tolerance:** stale entries are ignored. With no sidecar the app derives everything from the YAML: no prefix, case taken from the flags, and extra triggers shown as aliases.

### CLI calls

Commands run as child processes through the swift-subprocess library, with a timeout and stdout/stderr captured:

- `path`, `--version`, `status`, `start`, `restart`
- `cmd enable`, `cmd disable`
- `match list --json`, `match exec -t`
- `stats --json`, `stats clear`, `stats prune`
- `package install`, `package uninstall`, `package update`, `package list`

In 2.4.1, `status`, `start`, `restart`, `stop`, `install` and `uninstall` are hidden from the help output but still work as aliases.

## Gaps: Typinator features Espanso can't express

Twelve Typinator behaviors have no faithful Espanso equivalent. The app leaves them out or approximates them, and says so in the UI instead of silently behaving differently.

| Typinator feature | Handling in this design | Reason or workaround |
| --- | --- | --- |
| Feedback sounds | Not offered | Espanso has no expansion hook the app could listen to. |
| Delay marker `{delay:0.5}` | Not offered | No equivalent in Espanso. |
| Suppress This / Next Replacement (`{X}`, `{X>}`) | Not offered | No equivalent in Espanso. |
| Calculations | Not in v1 | Could later be built from a shell variable, for example with `bc`. |
| Keystroke markers (Tab, Return, arrows mid-expansion) | Not offered | Only literal newline and tab characters are possible in the text. |
| Persistent variables (e.g. `{{qq={clip}}}` clip collections) | Not offered | Espanso evaluates variables fresh on every expansion. |
| Input fields that remember the last value | Static default only | Espanso forms support a fixed `default`, not a remembered value. |
| Set priority for duplicate abbreviations | Badge plus Espanso's choice dialog | Espanso asks which match to use instead of picking the top set. |
| Case does not matter, for mixed casings like `bTw` | Three variants only | The emulation compiles lowercase, Capitalized and UPPERCASE triggers. |
| WYSIWYG formatted text (RTF) | Markdown or HTML in v1 | A rich-text editor that saves to `html:` could come later. |
| "." for recent items in Quick Search | Statistics database plus the app's own history | Espanso has no recency command, but its statistics database has a timestamp per expansion. With statistics off, only the app's own history is available. |
| Sync, iOS app, Apple Intelligence features | Out of scope | Users sync the Espanso folder themselves. |

## Open questions and verification spikes

Twelve facts could not be confirmed from the docs. Each is a short spike to run against a real Espanso 2.4.x install before the feature that depends on it is built. Together they form Phase 0 of the build. Answers are recorded in [`docs/espanso-facts.md`](docs/espanso-facts.md) as they come in; all twelve are answered there. Question 4 changed the Quick Search design: `match exec` deletes text before the cursor, so the app pastes plain-text snippets itself.

| # | Question | Blocks | How to check |
| --- | --- | --- | --- |
| 1 | On macOS, what does `filter_class` match (the docs say "App identifier"; is that the bundle ID?), and what exact path does `filter_exec` see? | Apps window | Type `#detect#` in Mail, VS Code and Chrome and record title, exec and class |
| 2 | Are triggers case-sensitive by default, and how does `propagate_case` treat a trigger with capitals in it? | Case pop-up | Test matches `btw` and `Btw` with and without the flag |
| 3 | Does `config/default.yml` accept `excludes` / `extra_excludes`? | Turning a package off everywhere without uninstalling it | Add an exclude for a package glob and check `espanso match list` |
| 4 | Is `espanso match exec -t` reliable from a panel, and how long a delay does focus need to return? | Quick Search | Run it from a test `NSPanel` into TextEdit, Mail and a browser |
| 5 | What does `espanso stats --json` return: fields, timestamps, and the accepted `--period` values? | Statistics view, recents | Turn stats on, expand a few triggers, inspect the output |
| 6 | What is the real default of `max_regex_buffer_size`? The options page says 30; the v2.3.0 release notes say 50. | Regex warnings | Test with a long regex match |
| 7 | How should `script` args point at a file in `$CONFIG/scripts/`? | Script… menu item | Try an absolute path and any config placeholder Espanso supports |
| 8 | Can the app ask whether Espanso is paused (for example after the toggle key was used)? | Menu bar state | Check `espanso status` output in both states |
| 9 | Can Yams or libyaml give start and end positions for every match node? | Surgical YAML writes | Prototype round-trip edits on commented fixture files |
| 10 | Does Espanso ignore the hidden `.abbrio/` folder without warnings or reloads? | Sidecar location | Write the sidecar and watch Espanso's log |
| 11 | What are the URL and fields of the Hub's `package_index.json` (tags, featured flag, dates, README, archive URL)? What are the exact uninstall and update subcommands, and does Espanso reload after an install without a restart? | Browse Hub tab, Update badges, snippets preview | Download the index from the espanso/hub releases and inspect it; run `espanso --help`; install a package and watch the log |
| 12 | Can the app name the process holding Secure Input (for example the `kCGSSessionSecureInputPID` value in `ioreg`)? | Menu bar status | Enable Secure Input in Terminal and query it |

## Build phases

The build runs in eight phases, each ending in an acceptance check. Every phase is usable on its own.

1. **Phase 0: Spikes.** Answer questions 1–12 above. Write the findings into `docs/espanso-facts.md` and adjust this spec where needed.
2. **Phase 1: Read-only browser.** Find the binary and config folder, read the version, parse match and config files, and build the three-pane window with search.
   - *Accept:* every match in a real config folder appears in the right set. Underscore files show as off, packages as locked, and broken files with an error badge.
3. **Phase 2: Editing core.** Plain-text editing, Case and Expand pop-ups, set create/rename/delete, surgical writes, backups, FSEvents reload, undo, autosave.
   - *Accept:* golden-file tests show that editing one match in a commented fixture changes only that match's bytes, and Espanso picks up the edit.
4. **Phase 3: Sets, sidecar and Apps.** Set Info, prefix/suffix compilation, "Case does not matter" emulation, the Apps window and `config/*.yml` generation.
   - *Accept:* the Apps grid survives an app restart. Each toggle produces the expected YAML from the compile rules. Overlapping filters are detected.
5. **Phase 4: Dynamic content.** The Insert menu: cursor, clipboard, date, input fields and pop-ups as forms, nested match, script and shell. Plus Markdown, HTML and Picture expansion types.
   - *Accept:* each menu item writes YAML that Espanso loads (`espanso match list --json`) and expands correctly in TextEdit.
6. **Phase 5: Menu bar, Quick Search, Quick Define.** The `MenuBarExtra`, status states, Pause/Resume, the Quick Search panel with insertion via `match exec`, Quick Define from clipboard and selection.
   - *Accept:* ⌃⌘S, type, Return inserts into the previously focused app. A new item from the clipboard expands right away.
7. **Phase 6: Settings, Statistics, Packages, Regex, Import/Export.** The `default.yml` settings UI, the stats view, the Packages view (Installed and Browse Hub tabs, detail sheet, Install from Git URL), the regex rule editor with tester, CSV import/export, and package export.
   - *Accept:* untouched settings are never written, stats match the `espanso stats` output, and an exported package installs with `espanso install --external`.
8. **Phase 7: Help.** The toolbar's Help button opens a small panel in the app's own style with three choices: a help center with guides and answers, opening a support request, and sending a technical bug report. Each opens in the browser: the help center at `https://getabbrio.com/help/`, and the two forms as new issues in the project's GitHub repository, with the templates `general-support-request.md` and `bug_report.md`. The Help menu in the menu bar holds the same three choices.
   - *Accept:* each of the three choices opens its destination, and the panel follows light and dark appearance.

**Suggested building blocks.** These are suggestions, to confirm during Phase 0. Each one's license must be checked against the MIT requirement above before it is added.

- SwiftUI plus AppKit (`NSPanel`, `NSTextView` with chip attachments)
- Yams (MIT) for parsing, with the app's own emitter for writing a match
- A global-hotkey package such as sindresorhus/KeyboardShortcuts
- `SMAppService` for launch at login
- XCTest with fixture config folders and golden-file YAML tests

## Sources

Pages opened while writing this spec (2026-11-11):

**Typinator**

- [How to start with Typinator](https://help.typinator.ergonis.com/hc/en-us/articles/22697102104348)
- [Set-specific settings in Typinator](https://help.typinator.ergonis.com/hc/en-us/articles/23136850315292-Set-specific-settings-in-Typinator)
- [When to use "Expand at Word Break" or "Expand on Match"](https://help.typinator.ergonis.com/hc/en-us/articles/22937741557020-When-to-Use-Expand-at-Word-Break-or-Expand-on-Match)
- [Types of case variations](https://help.typinator.ergonis.com/hc/en-us/articles/22938474545180)
- [Triggers for expansions](https://help.typinator.ergonis.com/hc/en-us/articles/22842375363868)
- [Advanced markers in Typinator](https://help.typinator.ergonis.com/hc/en-us/articles/23135814142620)
- [Typinator version history (Mac)](https://ergonis.com/en/typinator/version-history/mac/)

**Espanso**

- [Matches basics](https://espanso.org/docs/matches/basics)
- [Variables](https://espanso.org/docs/matches/variables)
- [Forms](https://espanso.org/docs/matches/forms)
- [Options reference](https://espanso.org/docs/configuration/options)
- [App-specific configurations](https://espanso.org/docs/configuration/app-specific-configurations)
- [Include and exclude rules](https://espanso.org/docs/configuration/include-and-exclude)
- [Statistics (CLI)](https://espanso.org/docs/command%20lIne/stats)
- [Espanso releases](https://www.github.com/espanso/espanso/releases)
- [Espanso repository](https://github.com/espanso/espanso) (license: GPL-3.0)

Also relied on from search excerpts, not opened in full: Typinator's [Activating sets for specific applications](https://help.typinator.ergonis.com/hc/en-us/articles/23136598976668-Activating-sets-for-specific-applications-in-Typinator), [What is Quick Search?](https://help.typinator.ergonis.com/hc/en-us/articles/22694736070940-What-is-Quick-Search) and [Creating and managing sets](https://help.typinator.ergonis.com/hc/en-us/articles/23136337032348-How-to-create-and-manage-abbreviation-sets-in-Typinator). Espanso's [Extensions](https://espanso.org/docs/matches/extensions), [Regex triggers](https://espanso.org/docs/matches/regex-triggers), [CLI reference](https://espanso.org/docs/command%20lIne/cli_list/), [Packages basics](https://espanso.org/docs/packages/basics) and [Getting started](https://espanso.org/docs/get-started).

For the Packages section: the [Espanso Hub search page](https://hub.espanso.org/search) and a [DeepWiki write-up of the Hub publishing pipeline](https://deepwiki.com/carlescarles/hub) (opened; the latter describes what appears to be a fork of espanso/hub). From search excerpts: Espanso's [External packages](https://espanso.org/docs/packages/external-packages).
