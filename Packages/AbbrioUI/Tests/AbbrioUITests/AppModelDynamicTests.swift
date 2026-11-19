import XCTest
import ConfigStore
import EspansoCLI
import SnippetModel
@testable import AbbrioUI

private struct NoRunner: CommandRunner {
    func run(
        _ executable: URL, arguments: [String], environment: [String: String]?, timeout: TimeInterval
    ) async throws -> CommandResult {
        throw CommandError.launchFailed("not available in tests")
    }
}

private let workFile = """
# Work
matches:
  - trigger: ";ty"
    replace: "Thanks. I'll reply by "
    label: Thanks   # keep
  - trigger: ";sig"
    form: "Regards, [[name]]"
  - trigger: ";logo"
    image_path: "/somewhere/else/logo.png"

"""

@MainActor
final class AppModelDynamicTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("abbrio-tests-" + UUID().uuidString)
            .appendingPathComponent("config-folder")
        for folder in ["match", "config"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("config/default.yml", "toggle_key: OFF\n")
        try write("match/work.yml", workFile)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func text(_ path: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    private func makeModel(selecting index: Int) async -> AppModel {
        let model = AppModel(
            environment: AppEnvironment(configFolderOverride: root, fallbackConfigFolders: []),
            runner: NoRunner(),
            locator: EspansoLocator(searchPath: "", isExecutable: { _ in false }),
            discard: { try FileManager.default.removeItem(at: $0) }
        )
        model.autosaveDelay = .seconds(3600)
        await model.load()
        model.selectedSetID = "work.yml"
        model.selectedSnippetID = Snippet.ID(file: "match/work.yml", index: index)
        return model
    }

    // MARK: Variables

    func testInsertingADateWritesTheVariableAndDeletingItsChipRemovesIt() async throws {
        let model = await makeModel(selecting: 0)
        let name = model.uniqueVariableName("date")
        XCTAssertEqual(name, "date1")
        let token = try XCTUnwrap(model.addVariable(SnippetVariable(name: name, type: "date", params: [
            ParamEntry("format", .string("%A")), ParamEntry("offset", .int(172800)),
        ])))
        model.setBody((model.draft?.body ?? "") + token)
        XCTAssertTrue(model.commitDraft())
        XCTAssertEqual(text("match/work.yml"), workFile.replacingOccurrences(
            of: "    replace: \"Thanks. I'll reply by \"\n    label: Thanks   # keep\n",
            with: """
                replace: "Thanks. I'll reply by {{date1}}"
                label: Thanks   # keep
                vars:
                  - name: date1
                    type: date
                    params:
                      format: "%A"
                      offset: 172800

            """
        ))

        // Deleting the chip in the text box takes the variable with it.
        model.setBody("Thanks. I'll reply by ")
        XCTAssertEqual(model.draft?.variables, [])
        // Undo in the text box brings the reference back, and the variable with it.
        model.setBody("Thanks. I'll reply by {{date1}}")
        XCTAssertEqual(model.draft?.variables.map(\.name), ["date1"])
        model.setBody("Thanks. I'll reply by ")
        XCTAssertTrue(model.commitDraft())
        XCTAssertEqual(text("match/work.yml"), workFile)

        // One Undo step brings the whole previous item back.
        model.undo()
        XCTAssertTrue(text("match/work.yml").contains("offset: 172800"))
    }

    func testAnInputFieldMakesAFormAndRemovingItGoesBackToPlainText() async throws {
        let model = await makeModel(selecting: 0)
        let token = try XCTUnwrap(model.addFormField(FormField(name: "day", label: "Day", defaultValue: "Friday")))
        XCTAssertEqual(token, "{{form1.day}}")
        model.setBody((model.draft?.body ?? "") + token)
        XCTAssertTrue(model.commitDraft())
        XCTAssertTrue(text("match/work.yml").contains("""
            vars:
              - name: form1
                type: form
                params:
                  layout: "Day: [[day]]"
                  fields:
                    day:
                      default: Friday

        """))
        model.removeFormField(named: "day")
        XCTAssertEqual(text("match/work.yml"), workFile)
    }

    func testAShortFormKeepsItsSyntaxUntilSomethingNeedsTheLongOne() async throws {
        let model = await makeModel(selecting: 1)
        XCTAssertEqual(model.draft?.isShortForm, true)
        var field = try XCTUnwrap(model.draft?.formField(named: "name"))
        XCTAssertNil(field.label)
        field.defaultValue = "Sam"
        model.updateFormField(named: "name", to: field)
        XCTAssertTrue(text("match/work.yml").contains("    form: \"Regards, [[name]]\"\n    form_fields:\n      name:\n        default: Sam\n"))

        // A second field stays in the short syntax too.
        let token = try XCTUnwrap(model.addFormField(FormField(name: "team", kind: .choice, values: ["A", "B"])))
        XCTAssertEqual(token, "[[team]]")
        model.setBody((model.draft?.body ?? "") + " " + token)
        XCTAssertTrue(model.commitDraft())
        XCTAssertTrue(text("match/work.yml").contains("    form: \"Regards, [[name]] [[team]]\"\n"))

        // The clipboard has no place in the short syntax, so the item is rewritten in the long one.
        let clip = try XCTUnwrap(model.addVariable(SnippetVariable(name: "clip1", type: "clipboard")))
        model.setBody((model.draft?.body ?? "") + clip)
        XCTAssertTrue(model.commitDraft())
        let written = text("match/work.yml")
        XCTAssertFalse(written.contains("form:"))
        XCTAssertFalse(written.contains("form_fields"))
        XCTAssertTrue(written.contains("    replace: Regards, {{form1.name}} {{form1.team}}{{clip1}}\n"))
        XCTAssertTrue(written.contains("layout: \"Name: [[name]]\\nTeam: [[team]]\""))
    }

    func testRemovingTheLastFieldOfAShortFormLeavesPlainText() async {
        let model = await makeModel(selecting: 1)
        model.removeFormField(named: "name")
        XCTAssertTrue(text("match/work.yml").contains("  - trigger: \";sig\"\n    replace: \"Regards, \"\n  - trigger: \";logo\""))
    }

    // MARK: Type

    func testTextMarkdownAndHTMLOnlyChangeTheKey() async {
        let model = await makeModel(selecting: 0)
        model.setKind(.markdown)
        XCTAssertEqual(text("match/work.yml"), workFile.replacingOccurrences(of: "    replace: \"Thanks", with: "    markdown: \"Thanks"))
        model.setKind(.html)
        XCTAssertEqual(text("match/work.yml"), workFile.replacingOccurrences(of: "    replace: \"Thanks", with: "    html: \"Thanks"))
        model.setKind(.text)
        XCTAssertEqual(text("match/work.yml"), workFile)
    }

    func testSwitchingToPictureKeepsTheTextUntilAPictureIsChosen() async throws {
        let model = await makeModel(selecting: 0)
        XCTAssertTrue(model.switchingToPictureDiscardsContent)
        model.setKind(.picture)
        // Nothing is written for a picture item without a picture.
        XCTAssertEqual(text("match/work.yml"), workFile)
        XCTAssertEqual(model.draft?.expansion, .image(path: ""))
        // Changing one's mind brings the text back.
        model.setKind(.markdown)
        XCTAssertEqual(model.draft?.expansion, .markdown("Thanks. I'll reply by "))
        model.setKind(.text)
        XCTAssertEqual(text("match/work.yml"), workFile)

        // A picture is copied, and only then is the item saved.
        let source = root.deletingLastPathComponent().appendingPathComponent("My Logo.PNG")
        let picture = try makePNG(width: 4, height: 3)
        try picture.write(to: source)
        let setPicture = await model.setPicture(from: source, referencingOriginal: false)
        XCTAssertTrue(setPicture)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/My-Logo.png")), picture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(text("match/work.yml"), workFile.replacingOccurrences(
            of: "    replace: \"Thanks. I'll reply by \"\n", with: "    image_path: \"$CONFIG/images/My-Logo.png\"\n"
        ))
        XCTAssertEqual(model.pictureURL(forPath: "$CONFIG/images/My-Logo.png")?.standardizedFileURL.path,
                       root.appendingPathComponent("images/My-Logo.png").standardizedFileURL.path)

        // Undo restores the whole previous item: its type and its text.
        model.undo()
        XCTAssertEqual(text("match/work.yml"), workFile)
        // The copied picture stays; other items may use it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/My-Logo.png").path))
    }

    func testPicturesAreNeverReplacedAndCanBeReferencedInPlace() async throws {
        let folder = root.deletingLastPathComponent()
        let first = folder.appendingPathComponent("a/logo.png"), second = folder.appendingPathComponent("b/logo.png")
        let firstPicture = try makePNG(width: 2, height: 2, red: 0.1), secondPicture = try makePNG(width: 2, height: 2, red: 0.9)
        for (url, bytes) in [(first, firstPicture), (second, secondPicture)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        XCTAssertEqual(try AppModel.copyPicture(first, contents: firstPicture, into: root), "logo.png")
        // The same picture again uses the copy that is there.
        XCTAssertEqual(try AppModel.copyPicture(first, contents: firstPicture, into: root), "logo.png")
        // A different picture with the same name gets its own name.
        XCTAssertEqual(try AppModel.copyPicture(second, contents: secondPicture, into: root), "logo-2.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("images/logo.png")), firstPicture)

        // An existing path is left alone until a new picture is chosen.
        let model = await makeModel(selecting: 2)
        XCTAssertEqual(model.draft?.expansion, .image(path: "/somewhere/else/logo.png"))
        model.updateDraft { $0.label = "Logo" }
        XCTAssertTrue(model.commitDraft())
        XCTAssertTrue(text("match/work.yml").contains("image_path: \"/somewhere/else/logo.png\"\n    label: Logo\n"))
        let referenced = await model.setPicture(from: second, referencingOriginal: true)
        XCTAssertTrue(referenced)
        XCTAssertTrue(text("match/work.yml").contains("image_path: \"\(second.path)\"\n"))
    }

    func testAFileThatIsNotAPictureIsRefusedBeforeAnythingIsCopied() async throws {
        let model = await makeModel(selecting: 0)
        let folder = root.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let notes = folder.appendingPathComponent("notes.png")
        try Data("not a picture".utf8).write(to: notes)
        let pipe = folder.appendingPathComponent("pipe.png")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)

        for url in [notes, pipe] {
            model.alertMessage = nil
            let accepted = await model.setPicture(from: url, referencingOriginal: false)
            XCTAssertFalse(accepted)
            XCTAssertNotNil(model.alertMessage)
            XCTAssertTrue(model.alertMessage?.hasPrefix(url.lastPathComponent + " can't be used as a picture") == true)
        }
        let referenced = await model.setPicture(from: notes, referencingOriginal: true)
        XCTAssertFalse(referenced)
        XCTAssertEqual(text("match/work.yml"), workFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
    }

    // MARK: Scripts and global variables

    func testAScriptIsWrittenToTheScriptsFolder() async throws {
        let model = await makeModel(selecting: 0)
        let variable = SnippetVariable(name: "script1", type: "script")
        let saved = try XCTUnwrap(model.saveScript("return \"hi\"", language: .appleScript, for: variable))
        XCTAssertEqual(saved.params["args"], .list([.string("osascript"), .string("%CONFIG%/scripts/script1.applescript")]))
        XCTAssertEqual(text("scripts/script1.applescript"), "return \"hi\"")
        XCTAssertEqual(model.scriptCode(of: saved), "return \"hi\"")
        XCTAssertEqual(model.scriptFile(of: saved)?.language, .appleScript)

        // Saving again updates the same file; another variable of the same name gets its own file.
        _ = model.saveScript("return \"hello\"", language: .appleScript, for: saved)
        XCTAssertEqual(text("scripts/script1.applescript"), "return \"hello\"")
        let other = try XCTUnwrap(model.saveScript("'x'", language: .javaScript, for: variable))
        XCTAssertEqual(other.params["args"]?.list?.compactMap(\.text), ["osascript", "-l", "JavaScript", "%CONFIG%/scripts/script1.js"])
        let third = try XCTUnwrap(model.saveScript("return 1", language: .appleScript, for: variable))
        XCTAssertEqual(third.params["args"]?.list?.last?.text, "%CONFIG%/scripts/script1-2.applescript")
        XCTAssertEqual(text("scripts/script1.applescript"), "return \"hello\"")

        // A script somewhere else is not the app's to edit.
        let foreign = SnippetVariable(name: "s", type: "script", params: [
            ParamEntry("args", .list([.string("python3"), .string("/tmp/x.py")])),
        ])
        XCTAssertNil(model.scriptFile(of: foreign))
    }

    func testAScriptNameThatWouldLeaveTheScriptsFolderIsRefused() async throws {
        let model = await makeModel(selecting: 0)
        for name in ["../../escape", "a/b", "..", ""] {
            XCTAssertNil(model.saveScript("return 1", language: .appleScript, for: SnippetVariable(name: name, type: "script")), name)
        }
        XCTAssertNotNil(model.alertMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.applescript").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts").path))
    }

    func testGlobalVariablesAreEditedInTheFile() async {
        let model = await makeModel(selecting: 0)
        let me = SnippetVariable(name: "me", type: "echo", params: [ParamEntry("echo", .string("Sam"))])
        XCTAssertNil(model.setGlobalVariables([me], inSet: "work.yml"))
        XCTAssertTrue(text("match/work.yml").hasPrefix("# Work\nglobal_vars:\n  - name: me\n    type: echo\n    params:\n      echo: Sam\n\nmatches:\n"))
        XCTAssertEqual(model.sets.first { $0.id == "work.yml" }?.globalVariableList, [me])
        XCTAssertEqual(model.editingGlobalVariables, [me])
        XCTAssertEqual(model.uniqueVariableName("me"), "me1")
        XCTAssertNotNil(model.setGlobalVariables([me, me], inSet: "work.yml"))
        model.undo()
        XCTAssertEqual(text("match/work.yml"), workFile)
    }
}
