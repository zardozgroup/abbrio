import XCTest
import SnippetModel
@testable import ConfigStore

/// What each item of the Insert menu, and each change of type, writes to a match file.
///
/// `Fixtures/golden/dynamic.expected.txt` holds, for every case, the lines that differ from
/// `dynamic.yml`. Every line outside them is identical by construction, and the test also checks that
/// they lie inside the edited match.
final class DynamicContentTests: XCTestCase {
    private let path = "match/dynamic.yml"
    private func fixture(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.resourceURL)
        return try Data(contentsOf: base.appendingPathComponent("Fixtures/golden").appendingPathComponent(name))
    }
    private func edit(_ index: Int, _ change: (inout MatchDraft) -> Void) throws -> String {
        let data = try fixture("dynamic.yml")
        let snippets = try MatchFileParser.parse(String(decoding: data, as: UTF8.self), path: path).snippets
        let snippet = try XCTUnwrap(snippets.first { $0.id.index == index })
        var draft = MatchDraft(snippet)
        change(&draft)
        let out = try MatchFileEditor.update(matchAt: index, with: draft, in: data, path: path)
        let old = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: out, as: UTF8.self).components(separatedBy: "\n")
        var head = 0
        while head < min(old.count, new.count), old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < min(old.count, new.count) - head, old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        // Nothing outside the match's own lines may differ.
        let range = try XCTUnwrap(snippet.sourceRange)
        XCTAssertGreaterThanOrEqual(head + 1, range.first)
        XCTAssertLessThanOrEqual(old.count - tail, range.last)
        // What was written reads back as the draft.
        let after = try MatchFileParser.parse(String(decoding: out, as: UTF8.self), path: path).snippets
        XCTAssertEqual(MatchDraft(try XCTUnwrap(after.first { $0.id.index == index })), draft)
        return "@@ from line \(head + 1), -\(old.count - head - tail) +\(new.count - head - tail)\n" + new[head..<(new.count - tail)].joined(separator: "\n")
    }

    func testEveryInsertMenuItemAndTypeChangeMatchesTheGoldenFile() throws {
        var out = ""
        func show(_ title: String, _ index: Int, _ change: (inout MatchDraft) -> Void) {
            do { out += "=== \(title)\n" + (try edit(index, change)) + "\n" } catch { out += "=== \(title)\nERROR \(error)\n" }
        }
        show("cursor", 0) { $0.body += "$|$" }
        show("clipboard", 0) { d in d.body += d.addVariable(SnippetVariable(name: d.uniqueName("clip"), type: "clipboard")) }
        show("date", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "date1", type: "date", params: [
                ParamEntry("format", .string("%A, %B %e, %Y")), ParamEntry("offset", .int(172800)),
                ParamEntry("locale", .string("en-US")), ParamEntry("tz", .string("America/Los_Angeles")),
            ]))
        }
        show("input field", 0) { d in d.body += d.addFormField(FormField(name: "first_name", label: "First name", defaultValue: "Thomas")) }
        show("popup in existing form", 1) { d in
            d.body += " " + d.addFormField(FormField(name: "title", label: "Title", kind: .choice, defaultValue: "Dr", values: ["Dr", "Prof", "yes"]))
        }
        show("list with separator", 1) { d in
            d.body += d.addFormField(FormField(name: "tags", label: "Tags", kind: .list, values: ["a", "b"], separator: "; "))
        }
        show("match", 0) { d in d.body += d.addVariable(SnippetVariable(name: "abbr1", type: "match", params: [ParamEntry("trigger", .string(";sig"))])) }
        show("script", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "script1", type: "script", params: [
                ParamEntry("args", .list([.string("osascript"), .string("%CONFIG%/scripts/script1.applescript")])),
            ]))
        }
        show("script js", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "script1", type: "script", params: [
                ParamEntry("args", .list([.string("osascript"), .string("-l"), .string("JavaScript"), .string("%CONFIG%/scripts/script1.js")])),
            ]))
        }
        show("choice", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "choice1", type: "choice", params: [
                ParamEntry("values", .list([.string("Plain one"), .map([ParamEntry("label", .string("Shown")), ParamEntry("id", .string("inserted: text"))])])),
            ]))
        }
        show("random", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "random1", type: "random", params: [
                ParamEntry("choices", .list([.string("Hi"), .string("Hello there"), .string("no")])),
            ]))
        }
        show("shell", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "shell1", type: "shell", params: [ParamEntry("cmd", .string("date +%s | tr -d '\\n'"))]))
        }
        show("shell multiline", 0) { d in
            d.body += d.addVariable(SnippetVariable(name: "shell1", type: "shell", params: [ParamEntry("cmd", .string("echo one\necho two"))]))
        }
        show("short: edit field", 2) { d in
            var f = d.formField(named: "team")!; f.values = ["Support", "Sales", "Billing"]; f.defaultValue = "Sales"
            d.updateFormField(named: "team", to: f)
        }
        show("short: add field", 2) { d in d.body += d.addFormField(FormField(name: "phone", defaultValue: "555")) }
        show("short: rename field", 2) { d in var f = d.formField(named: "name")!; f.name = "who"; f.isMultiline = true; d.updateFormField(named: "name", to: f) }
        show("short: add clipboard converts", 2) { d in d.body += d.addVariable(SnippetVariable(name: "clip1", type: "clipboard")) }
        show("short: remove one field", 2) { d in d.removeFormField(named: "team") }
        show("short: remove all fields", 2) { d in d.removeFormField(named: "team"); d.removeFormField(named: "name") }
        show("verbose: remove one", 1) { d in d.removeFormField(named: "first_name") }
        show("verbose: remove all", 1) { d in d.removeFormField(named: "first_name"); d.removeFormField(named: "last_name") }
        show("verbose: relabel+rename", 1) { d in var f = d.formField(named: "last_name")!; f.label = "Surname"; f.name = "surname"; d.updateFormField(named: "last_name", to: f) }
        show("due: change clock only", 3) { d in var v = d.variables[1]; v.params["format"] = .string("%I:%M %p"); d.updateVariable(named: "clock", to: v) }
        show("due: delete chip text", 3) { d in let old = d.body; d.body = "Due {{due}}"; d.reconcile(afterBodyChangedFrom: old) }
        show("due: rename", 3) { d in var v = d.variables[0]; v.name = "deadline"; d.updateVariable(named: "due", to: v) }
        show("markdown", 0) { $0.setTextKind(.markdown) }
        show("html multi", 0) { d in d.setTextKind(.html); d.body = "<p>Thanks</p>\n<p>Bye</p>" }
        show("picture", 0) { d in d.expansion = .image(path: "$CONFIG/images/logo.png") }
        show("short to markdown", 2) { $0.setTextKind(.markdown) }
        if let scratch = ProcessInfo.processInfo.environment["ABBRIO_WRITE_GOLDEN"] {
            try out.write(toFile: scratch, atomically: true, encoding: .utf8)
        }
        let expected = String(decoding: try fixture("dynamic.expected.txt"), as: UTF8.self)
        func sections(_ text: String) -> [String: String] {
            var result: [String: String] = [:]
            for part in text.components(separatedBy: "=== ").dropFirst() {
                let title = String(part.prefix { $0 != "\n" })
                result[title] = part
            }
            return result
        }
        let want = sections(expected), got = sections(out)
        XCTAssertEqual(want.keys.sorted(), got.keys.sorted())
        for title in want.keys.sorted() {
            XCTAssertEqual(got[title], want[title], title)
        }
    }

    // MARK: Reading

    func testParametersKeepTheirKinds() throws {
        let text = """
        matches:
          - trigger: a
            replace: "{{v}}"
            vars:
              - name: v
                type: date
                params:
                  format: "%Y"
                  offset: 604800
                  quoted: "12"
                  flag: true
                  loose: yes
                  ratio: 1.5
                  empty:
                  list: [a, 2]
                depends_on: [w]
        """
        let variable = try XCTUnwrap(try MatchFileParser.parse(text, path: path).snippets.first?.variables.first)
        XCTAssertEqual(variable.params, [
            ParamEntry("format", .string("%Y")), ParamEntry("offset", .int(604800)), ParamEntry("quoted", .string("12")),
            ParamEntry("flag", .bool(true)), ParamEntry("loose", .other("yes")), ParamEntry("ratio", .other("1.5")),
            ParamEntry("empty", .other("")), ParamEntry("list", .list([.string("a"), .int(2)])),
        ])
        XCTAssertEqual(variable.extras, [ParamEntry("depends_on", .list([.string("w")]))])
        // Written out again, every kind comes back as it was.
        let lines = try YAMLEmitter.variableLines(variable, indent: 6)
        let again = "matches:\n  - trigger: a\n    replace: x\n    vars:\n" + lines.joined(separator: "\n") + "\n"
        XCTAssertEqual(try MatchFileParser.parse(again, path: path).snippets.first?.variables.first, variable)
    }

    func testAListThatHoldsMoreThanVariablesIsLeftToTheYAMLTab() throws {
        let text = "matches:\n  - trigger: a\n    replace: x\n    vars:\n      - name: v\n        type: clipboard\n      - just text\n"
        let snippet = try XCTUnwrap(try MatchFileParser.parse(text, path: path).snippets.first)
        XCTAssertTrue(snippet.needsAdvancedYAML)
        var draft = MatchDraft(snippet)
        draft.variables = []
        XCTAssertThrowsError(try MatchFileEditor.update(matchAt: 0, with: draft, in: Data(text.utf8), path: path))
    }

    func testANewItemIsWrittenWithItsVariables() throws {
        var draft = MatchDraft(triggers: [";now"], expansion: .text("It is "))
        draft.body += draft.addVariable(SnippetVariable(name: "date1", type: "date", params: [ParamEntry("format", .string("%H:%M"))]))
        let (data, index) = try MatchFileEditor.append(draft, to: Data("matches: []\n".utf8), path: path)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), """
        matches:
          - trigger: ";now"
            replace: It is {{date1}}
            vars:
              - name: date1
                type: date
                params:
                  format: "%H:%M"

        """)
    }

    // MARK: Undoing a deletion in the text

    func testDeletedReferencesComeBackWithTheirVariables() throws {
        let data = try fixture("dynamic.yml")
        let snippets = try MatchFileParser.parse(String(decoding: data, as: UTF8.self), path: path).snippets
        for index in 1...3 {
            let original = MatchDraft(snippets[index])
            var memory = DynamicContentMemory()
            memory.record(original)
            var draft = original
            draft.body = "nothing left"
            draft.reconcile(afterBodyChangedFrom: original.body)
            XCTAssertTrue(draft.variables.isEmpty, "match \(index)")
            XCTAssertTrue(draft.formFields.isEmpty)
            XCTAssertFalse(draft.isShortForm)
            // The text comes back, as after Undo in the text box.
            let emptied = draft.body
            draft.body = original.body
            draft.reconcile(afterBodyChangedFrom: emptied)
            memory.restore(into: &draft)
            XCTAssertEqual(draft.expansion, original.expansion, "match \(index)")
            XCTAssertEqual(draft.formFields, original.formFields)
            XCTAssertEqual(draft.variables.map(\.name).sorted(), original.variables.map(\.name).sorted())
            XCTAssertEqual(draft.formFieldList.map(\.name), original.formFieldList.map(\.name))
            XCTAssertEqual(draft.formField(named: "first_name")?.defaultValue, original.formField(named: "first_name")?.defaultValue)
        }
    }

    func testAVariableUsedByAnotherIsKept() {
        var draft = MatchDraft(triggers: ["a"], expansion: .text("{{clip1}} {{shell1}}"), variables: [
            SnippetVariable(name: "clip1", type: "clipboard"),
            SnippetVariable(name: "shell1", type: "shell", params: [ParamEntry("cmd", .string("echo $ESPANSO_CLIP1"))]),
        ])
        let old = draft.body
        draft.body = "{{shell1}}"
        draft.reconcile(afterBodyChangedFrom: old)
        XCTAssertEqual(draft.variables.map(\.name), ["clip1", "shell1"])
    }

    // MARK: Global variables

    func testGlobalVariablesAreRewrittenInPlace() throws {
        let before = try fixture("commented.yml")
        let parsed = try MatchFileParser.parse(String(decoding: before, as: UTF8.self), path: path)
        var variables = parsed.globalVariableList
        XCTAssertEqual(variables, [SnippetVariable(name: "desk", type: "echo", params: [ParamEntry("echo", .string("Harbour Street Support"))])])
        variables.append(SnippetVariable(name: "year", type: "date", params: [ParamEntry("format", .string("%Y"))]))
        let added = try MatchFileEditor.setGlobalVariables(variables, in: before, path: path)
        XCTAssertEqual(String(decoding: added, as: UTF8.self), String(decoding: before, as: UTF8.self).replacingOccurrences(
            of: "      echo: Harbour Street Support\n",
            with: "      echo: Harbour Street Support\n  - name: year\n    type: date\n    params:\n      format: \"%Y\"\n"
        ))
        // Taking it away again gives the first file back, byte for byte.
        XCTAssertEqual(try MatchFileEditor.setGlobalVariables(parsed.globalVariableList, in: added, path: path), before)
        XCTAssertThrowsError(try MatchFileEditor.setGlobalVariables(variables + variables, in: before, path: path))
    }

    func testGlobalVariablesAreAddedAboveTheMatches() throws {
        let before = Data("# Notes\n\n# The list\nmatches:\n  - trigger: a\n    replace: b\n".utf8)
        let variable = SnippetVariable(name: "me", type: "echo", params: [ParamEntry("echo", .string("Sam"))])
        let after = try MatchFileEditor.setGlobalVariables([variable], in: before, path: path)
        XCTAssertEqual(String(decoding: after, as: UTF8.self), """
        # Notes

        global_vars:
          - name: me
            type: echo
            params:
              echo: Sam

        # The list
        matches:
          - trigger: a
            replace: b

        """)
        let removed = try MatchFileEditor.setGlobalVariables([], in: after, path: path)
        XCTAssertEqual(try MatchFileParser.parse(String(decoding: removed, as: UTF8.self), path: path).snippets.count, 1)
        XCTAssertFalse(String(decoding: removed, as: UTF8.self).contains("global_vars"))
    }
}
