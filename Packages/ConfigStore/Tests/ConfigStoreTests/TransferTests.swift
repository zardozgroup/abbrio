import XCTest
import SnippetModel
@testable import ConfigStore

final class TransferTests: XCTestCase {
    // MARK: Import

    func testImportedItemsAreWrittenAsOneNewFile() throws {
        let config = try TemporaryConfig(files: ["match/base.yml": "matches: []\n"])
        let source = SnippetImport(text: "abbreviation,expansion,description\n;sig,\"Best regards,\nRobin\",Sign-off\n:adr,1 Main St: back door,\n;q,\"say \"\"hi\"\"\",\n")
        let outcome = try SetManager(writer: ConfigWriter(root: config.root)).createSet(named: "From Sheet", holding: source.drafts)
        XCTAssertEqual(outcome.id, "from-sheet.yml")
        XCTAssertEqual(config.text("match/from-sheet.yml"), """
        matches:
          - trigger: ";sig"
            replace: |-
              Best regards,
              Robin
            label: Sign-off
          - trigger: ":adr"
            replace: "1 Main St: back door"
          - trigger: ";q"
            replace: say "hi"

        """)
        XCTAssertEqual(config.text("match/base.yml"), "matches: []\n")
        let set = try XCTUnwrap(ConfigLoader(root: config.root).load().sets.first { $0.id == "from-sheet.yml" })
        XCTAssertEqual(set.snippets.map(MatchDraft.init), source.drafts)
    }

    func testImportingNothingWritesAnEmptySetAndATakenNameGetsANumber() throws {
        let config = try TemporaryConfig(files: ["match/list.yml": "matches: []\n"])
        let outcome = try SetManager(writer: ConfigWriter(root: config.root)).createSet(named: "List", holding: [])
        XCTAssertEqual(outcome.id, "list-2.yml")
        XCTAssertEqual(config.text("match/list-2.yml"), "matches: []\n")
    }

    // MARK: Package export

    private let snippets = [
        Snippet(id: .init(file: "a.yml", index: 0), triggers: [";sig", ";s"], expansion: .text("Best regards,\nRobin"), label: "Sign-off"),
        Snippet(id: .init(file: "a.yml", index: 1), triggers: ["`tick"], expansion: .text("a *starred* line that goes on for quite a while, well past the point where it is cut")),
        Snippet(id: .init(file: "a.yml", index: 2), triggers: [], regex: #":(?P<n>\d+)usd;"#, expansion: .text("{{n}} dollars")),
    ]

    func testAPackageFolderHoldsTheSetTheManifestAndAReadme() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let matchFile = Data("# mine\nmatches:\n  - trigger: \";sig\"\n    replace: hello\n".utf8)
        let manifest = PackageManifest(
            name: "office-phrases", title: "Office Phrases", description: "Phrases: \"short\" ones",
            version: "1.2.0", author: "Robin Example"
        )
        let folder = try PackageExporter.export(matchFile: matchFile, snippets: snippets, manifest: manifest, to: parent)
        XCTAssertEqual(folder.lastPathComponent, "office-phrases")
        func text(_ name: String) throws -> String {
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("package.yml")), matchFile)
        XCTAssertEqual(try text("_manifest.yml"), """
        name: "office-phrases"
        title: "Office Phrases"
        description: "Phrases: \\"short\\" ones"
        version: "1.2.0"
        author: "Robin Example"

        """)
        XCTAssertEqual(try text("README.md"), """
        # Office Phrases

        Phrases: "short" ones

        Version 1.2.0, by Robin Example.

        ## Install

        Put this folder in a git repository of its own, then run:

            espanso install office-phrases --git <repository URL> --external

        ## Contents

        - `;sig`, `;s`: Sign-off
        - `` `tick ``: a \\*starred\\* line that goes on for quite a while, well past the point w\u{2026}
        - `:(?P<n>\\d+)usd;`: {{n}} dollars

        """)
        // A second export does not replace the first.
        XCTAssertThrowsError(try PackageExporter.export(matchFile: matchFile, snippets: [], manifest: manifest, to: parent))
    }

    // MARK: Installed and unpacked packages

    func testAnInstalledPackageCarriesItsManifestAndSource() throws {
        let config = try TemporaryConfig(files: [
            "match/packages/dice/_manifest.yml": "name: \"dice\"\ntitle: \"Dice Roller\"\ndescription: Rolls dice\nversion: 0.3.0\nauthor: Ann\ntags: [\"fun\", \"utility\"]\nhomepage: \"https://example.invalid/dice\"\n",
            "match/packages/dice/_pkgsource.yml": "hub\n",
            "match/packages/dice/package.yml": "matches:\n  - trigger: \":d6\"\n    replace: six\n",
            "match/packages/mine/_pkgsource.yml": "!git\nrepo_url: https://example.invalid/me/mine\nrepo_branch: null\nuse_native_git: false\n",
            "match/packages/mine/package.yml": "matches: []\n",
        ])
        let sets = ConfigLoader(root: config.root).load().sets
        let dice = try XCTUnwrap(sets.first { $0.id == "packages/dice" })
        XCTAssertEqual(dice.packageInfo, PackageInfo(
            name: "dice", title: "Dice Roller", description: "Rolls dice", version: "0.3.0", author: "Ann",
            tags: ["fun", "utility"], homepage: "https://example.invalid/dice", source: .hub
        ))
        XCTAssertEqual(dice.packageVersion, "0.3.0")
        let mine = try XCTUnwrap(sets.first { $0.id == "packages/mine" })
        XCTAssertEqual(mine.packageInfo, PackageInfo(name: "mine", source: .git("https://example.invalid/me/mine")))
        XCTAssertNil(mine.packageVersion)
    }

    func testArchiveTextsGiveTheReadmeAndItems() {
        let contents = PackageFiles.contents(entries: [
            (name: "dice-0.3.0/package.yml", text: "matches:\n  - trigger: \":d6\"\n    replace: six\n  - regex: \":d(?P<n>\\\\d+)\"\n    replace: roll\n"),
            (name: "dice-0.3.0/README.md", text: "\u{FEFF}# Dice\n\nRolls *dice*.\n"),
            (name: "dice-0.3.0/extra.yml", text: "matches: [oops"),
            (name: "dice-0.3.0/_manifest.yml", text: "name: dice\n"),
        ])
        XCTAssertEqual(contents.readme, "# Dice\n\nRolls *dice*.\n")
        XCTAssertEqual(contents.snippets.map(\.triggers), [[":d6"], []])
        XCTAssertEqual(contents.snippets.last?.regex, #":d(?P<n>\d+)"#)
        XCTAssertTrue(contents.hasUnreadableFiles)
        XCTAssertTrue(PackageFiles.contents(entries: [], unreadable: true).hasUnreadableFiles)
    }

    // MARK: Archive listings

    private func listing(_ lines: [String]) -> String {
        "Archive:  package.zip\nZip file size: 999 bytes, number of entries: \(lines.count)\n"
            + lines.joined(separator: "\n") + "\n\(lines.count) files, 0 bytes uncompressed, 0 bytes compressed:  0.0%\n"
    }

    private func line(_ name: String, size: Int = 10, kind: Character = "-", flags: String = "b-") -> String {
        "\(kind)rw-r--r--  2.0 unx \(String(repeating: " ", count: max(1, 8 - String(size).count)))\(size) \(flags) defN 20241206.024640 \(name)"
    }

    func testAnOrdinaryArchiveListingIsRead() throws {
        let entries = try PackageArchive.entries(fromListing: listing([
            line("_manifest.yml", size: 220), line("README.md", size: 240), line("package.yml", size: 4344),
            line("pkg dir/", size: 0, kind: "d", flags: "bx"), line("pkg dir/two words.yml", size: 3, flags: "tx"),
        ]))
        XCTAssertEqual(entries.map(\.name), ["_manifest.yml", "README.md", "package.yml", "pkg dir/", "pkg dir/two words.yml"])
        XCTAssertEqual(entries.map(\.size), [220, 240, 4344, 0, 3])
        XCTAssertEqual(entries[3].kind, .folder)
        let toRead = PackageArchive.entriesToRead(entries)
        XCTAssertEqual(toRead.read.map(\.name), ["README.md", "package.yml", "pkg dir/two words.yml"])
        XCTAssertFalse(toRead.skipped)
    }

    func testHostileArchivesAreRefused() {
        func refused(_ lines: [String], _ text: String? = nil) -> String? {
            do {
                _ = try PackageArchive.entries(fromListing: text ?? listing(lines))
                return nil
            } catch {
                return error.message
            }
        }
        XCTAssertEqual(refused([line("link.yml", kind: "l")]), "The archive holds links.")
        XCTAssertEqual(refused([line("secret.yml", flags: "TX")]), "The archive holds encrypted files.")
        XCTAssertEqual(refused([line("../escape.yml")]), "The archive holds a file with an unsafe name.")
        XCTAssertEqual(refused([line("/etc/x.yml")]), "The archive holds a file with an unsafe name.")
        XCTAssertEqual(refused([line("a*.yml")]), "The archive holds a file with an unsafe name.")
        XCTAssertEqual(refused([line("-p.yml")]), "The archive holds a file with an unsafe name.")
        XCTAssertEqual(refused([line("a\\b.yml")]), "The archive holds a file with an unsafe name.")
        XCTAssertEqual(refused([line("a.yml"), line("A.yml")]), "The archive holds two files with the same name.")
        XCTAssertEqual(refused([line("bomb.yml", size: 33 * 1024 * 1024)]), "The archive would unpack to more than 32 MB.")
        XCTAssertEqual(
            refused((0...PackageArchive.entryLimit).map { line("f\($0).yml", size: 1) }), "The archive holds too many files."
        )
        // A listing whose count does not match what was understood is not trusted.
        XCTAssertEqual(
            refused([], "Zip file size: 9 bytes, number of entries: 2\n" + line("a.yml") + "\n"),
            "The archive's list of files could not be read."
        )
        XCTAssertEqual(refused([], "End-of-central-directory signature not found.\n"), "The archive's list of files could not be read.")
    }

    func testLargeAndHiddenFilesAreNotRead() throws {
        let entries = try PackageArchive.entries(fromListing: listing([
            line("big.yml", size: PackageArchive.fileLimit + 1), line("__MACOSX/._package.yml"),
            line(".hidden/package.yml"), line("package.yml"), line("notes.txt"),
        ]))
        let toRead = PackageArchive.entriesToRead(entries)
        XCTAssertEqual(toRead.read.map(\.name), ["package.yml"])
        XCTAssertTrue(toRead.skipped)
    }

    func testAManifestIsCheckedBeforeAnythingIsWritten() {
        XCTAssertNil(PackageManifest(name: "a-1", title: "A", version: "0.1.0").problem)
        XCTAssertNotNil(PackageManifest(name: "", title: "A").problem)
        XCTAssertNotNil(PackageManifest(name: "My Set", title: "A").problem)
        XCTAssertNotNil(PackageManifest(name: "-a", title: "A").problem)
        XCTAssertNotNil(PackageManifest(name: "a", title: " ").problem)
        XCTAssertNotNil(PackageManifest(name: "a", title: "A", version: "1.0").problem)
        XCTAssertNotNil(PackageManifest(name: "a", title: "A", version: "1.x.0").problem)
        XCTAssertEqual(PackageManifest.name(forSetNamed: "Office Phrases"), "office-phrases")
    }
}
