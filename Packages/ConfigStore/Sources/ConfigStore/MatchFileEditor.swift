public import Foundation
public import SnippetModel

/// Changes the text of a match file while leaving every byte outside the touched lines as it was.
///
/// Each function takes the file's bytes and returns the new bytes. Nothing here touches the disk. The result
/// is parsed again before it is returned, and an error is thrown when it doesn't hold what was intended.
public enum MatchFileEditor {
    /// The order keys are written in for a new match, and where a new key is put in an existing one.
    private static let keyOrder = [
        "trigger", "triggers", "regex", "replace", "markdown", "html", "image_path", "form", "form_fields",
        "label", "search_terms", "word", "left_word", "right_word", "propagate_case", "uppercase_style",
        "force_mode", "paragraph", "vars",
    ]

    // MARK: Update

    /// Applies a draft to the match at `index`. Only the keys whose values changed are rewritten.
    public static func update(matchAt index: Int, with draft: MatchDraft, in data: Data, path: String) throws(EditError) -> Data {
        try validate(draft)
        var document = try SourceDocument(data)
        let parsed = try parse(document, path: path)
        guard let snippet = parsed.snippets.first(where: { $0.id.index == index }) else {
            throw .notEditable("The item is no longer in the file.")
        }
        guard !snippet.needsAdvancedYAML, let layout = parsed.layouts[index] else {
            throw .notEditable("This item uses YAML the form can't change. Use the YAML tab.")
        }
        let old = MatchDraft(snippet)
        guard old != draft else { return data }
        guard old.isRegex == draft.isRegex else {
            throw .notEditable("An abbreviation can't be turned into a regular-expression rule, or the other way round.")
        }

        var chunks = self.chunks(of: layout, in: document)
        let keyIndent = layout.indent + 2
        func style(_ key: String) -> ScalarStyle? {
            layout.keys.first { $0.name == key }?.style
        }

        if old.triggers != draft.triggers {
            try setTriggers(draft.triggers, in: &chunks, keyIndent: keyIndent, style: style("trigger"))
        }
        if old.regex != draft.regex, let regex = draft.regex {
            set("regex", try YAMLEmitter.lines(key: "regex", string: regex, indent: keyIndent, prefer: style("regex")), in: &chunks)
        }
        let key = expansionKey(draft.expansion)
        if !sameKind(old.expansion, draft.expansion) {
            // The text moves to another key, in the place of the old one.
            let core = try YAMLEmitter.lines(key: key, string: draft.body, indent: keyIndent)
            if let position = chunks.firstIndex(where: { $0.name == expansionKey(old.expansion) }) {
                chunks[position].name = key
                chunks[position].core = core
            } else {
                set(key, core, in: &chunks)
            }
        } else if old.body != draft.body {
            set(key, try YAMLEmitter.lines(key: key, string: draft.body, indent: keyIndent, prefer: style(key)), in: &chunks)
        }
        if old.formFields != draft.formFields {
            set("form_fields", draft.formFields.isEmpty ? nil : try YAMLEmitter.lines(
                key: "form_fields", value: .map(draft.formFields), indent: keyIndent
            ), in: &chunks)
        }
        if old.variables != draft.variables {
            let existing = chunks.first { $0.name == "vars" }.map { (old.variables, $0.core) }
            set("vars", draft.variables.isEmpty ? nil : try YAMLEmitter.variableListLines(
                key: "vars", variables: draft.variables, old: existing, indent: keyIndent
            ), in: &chunks)
        }
        if old.label != draft.label {
            set("label", draft.label.isEmpty ? nil : try YAMLEmitter.lines(
                key: "label", string: draft.label, indent: keyIndent, prefer: style("label")
            ), in: &chunks)
        }
        if old.searchTerms != draft.searchTerms {
            set("search_terms", draft.searchTerms.isEmpty ? nil : try YAMLEmitter.lines(
                key: "search_terms", strings: draft.searchTerms, indent: keyIndent
            ), in: &chunks)
        }
        for (key, before, after) in flags(old.options, draft.options) where before != after {
            set(key, after ? YAMLEmitter.lines(key: key, bool: true) : nil, in: &chunks)
        }
        if old.options.uppercaseStyle != draft.options.uppercaseStyle {
            set("uppercase_style", draft.options.uppercaseStyle.map { ["uppercase_style: \($0.rawValue)"] }, in: &chunks)
        }
        if old.options.forceMode != draft.options.forceMode {
            set("force_mode", draft.options.forceMode.map { ["force_mode: \($0.rawValue)"] }, in: &chunks)
        }

        document.replace(first: layout.range.first, last: layout.range.last, with: lines(of: chunks, indent: layout.indent))

        let result = try parse(document, path: path)
        guard result.snippets.count == parsed.snippets.count,
              let updated = result.snippets.first(where: { $0.id.index == index }),
              MatchDraft(updated) == draft
        else {
            throw .verificationFailed("The change could not be written safely. The file was left as it is.")
        }
        try checkOthersUnchanged(before: parsed, after: result, except: index)
        return document.data
    }

    // MARK: Triggers of many matches

    /// Replaces the triggers of several matches in one go, for a change of the set's prefix or suffix.
    ///
    /// - Parameter triggers: The new triggers, keyed by each match's position in the list.
    /// - Throws: `notEditable`, naming the items, when one of them is written in a way the form can't change.
    ///   Nothing is changed then.
    public static func replaceTriggers(_ triggers: [Int: [String]], in data: Data, path: String) throws(EditError) -> Data {
        var document = try SourceDocument(data)
        let parsed = try parse(document, path: path)
        var changes: [(snippet: Snippet, layout: MatchLayout?, triggers: [String])] = []
        for snippet in parsed.snippets {
            guard let new = triggers[snippet.id.index], new != snippet.triggers else { continue }
            guard !new.isEmpty, !new.contains(where: \.isEmpty) else {
                throw .invalidDraft("A trigger can't be empty.")
            }
            changes.append((snippet, snippet.needsAdvancedYAML ? nil : parsed.layouts[snippet.id.index], new))
        }
        let stuck = changes.filter { $0.layout == nil }.map(\.snippet.abbreviation)
        guard stuck.isEmpty else {
            throw .notEditable(
                "These items use YAML the form can't change, so the triggers were left as they are: "
                    + stuck.joined(separator: ", ") + ". Change them on the YAML tab first."
            )
        }
        guard !changes.isEmpty else { return data }

        // From the bottom up, so the line numbers of the matches above stay valid.
        for change in changes.sorted(by: { $0.snippet.id.index > $1.snippet.id.index }) {
            guard let layout = change.layout else { continue }
            var chunks = self.chunks(of: layout, in: document)
            try setTriggers(
                change.triggers, in: &chunks, keyIndent: layout.indent + 2,
                style: layout.keys.first { $0.name == "trigger" }?.style
            )
            document.replace(first: layout.range.first, last: layout.range.last, with: lines(of: chunks, indent: layout.indent))
        }

        let result = try parse(document, path: path)
        guard result.snippets.count == parsed.snippets.count, result.problems == parsed.problems,
              result.imports == parsed.imports, result.globalVariableNames == parsed.globalVariableNames
        else {
            throw .verificationFailed("The triggers could not be rewritten safely. The file was left as it is.")
        }
        for (before, after) in zip(parsed.snippets, result.snippets) {
            if let new = triggers[before.id.index], new != before.triggers {
                var expected = MatchDraft(before)
                expected.triggers = new
                guard MatchDraft(after) == expected, after.unknownKeys == before.unknownKeys else {
                    throw .verificationFailed("The triggers could not be rewritten safely. The file was left as it is.")
                }
            } else if after.source != before.source {
                throw .verificationFailed("The change would have altered other items. The file was left as it is.")
            }
        }
        return document.data
    }

    // MARK: Copy between files

    /// Copies the match at `index`, as written and with the comment lines directly above it, to the end of
    /// another file's list. Returns the copy's position there.
    public static func copy(
        matchAt index: Int, from source: Data, path sourcePath: String, to target: Data, path targetPath: String
    ) throws(EditError) -> (data: Data, index: Int) {
        let sourceDocument = try SourceDocument(source)
        let sourceParsed = try parse(sourceDocument, path: sourcePath)
        guard let range = sourceParsed.itemRanges[index],
              let original = sourceParsed.snippets.first(where: { $0.id.index == index })
        else {
            throw .notEditable("This item can't be moved from the form. Edit the file as YAML.")
        }
        // An alias would point at an anchor that stays behind.
        let dashContent = sourceDocument.line(range.first).drop { $0 == " " }.dropFirst().drop { $0 == " " }
        guard dashContent.first != "*", !original.source.contains("<<:") else {
            throw .notEditable("This item refers to another part of its file, so it can't be moved. Edit the file as YAML.")
        }
        let first = sourceParsed.leadingComments[index]?.first ?? range.first
        var moved = (first...range.last).map { sourceDocument.line($0) }
        let sourceIndent = sourceDocument.line(range.first).prefix { $0 == " " }.count

        var document = try SourceDocument(target)
        let parsed = try parse(document, path: targetPath)
        let newIndex = parsed.itemCount
        var targetIndent = 2
        if parsed.itemCount > 0 {
            guard let last = parsed.itemRanges[parsed.itemCount - 1] else {
                throw .notEditable("Items can't be added to \(targetPath) from the form. Edit the file as YAML.")
            }
            targetIndent = document.line(last.first).prefix { $0 == " " }.count
        }
        if targetIndent != sourceIndent {
            var shifted: [String] = []
            for line in moved {
                if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    shifted.append("")
                } else if targetIndent > sourceIndent {
                    shifted.append(String(repeating: " ", count: targetIndent - sourceIndent) + line)
                } else {
                    let remove = sourceIndent - targetIndent
                    guard line.prefix(remove).allSatisfy({ $0 == " " }), line.count >= remove else {
                        throw .notEditable("This item's lines can't be fitted into \(targetPath). Edit the file as YAML.")
                    }
                    shifted.append(String(line.dropFirst(remove)))
                }
            }
            moved = shifted
        }

        if parsed.itemCount > 0, let last = parsed.itemRanges[parsed.itemCount - 1] {
            if parsed.itemCount > 1, itemsAreSeparatedByBlankLines(parsed, document) {
                moved.insert("", at: 0)
            }
            document.replace(first: last.last + 1, last: last.last, with: moved)
        } else if let keyLine = parsed.matchesKeyLine {
            let line = document.line(keyLine)
            let rest = line.dropFirst("matches:".count).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("matches:"), ["", "[]", "~", "null"].contains(rest) else {
                throw .notEditable("Items can't be added to \(targetPath) from the form. Edit the file as YAML.")
            }
            document.replace(first: keyLine, last: keyLine, with: ["matches:"] + moved)
        } else {
            var new = ["matches:"] + moved
            if document.count > 0, !document.isBlank(document.count) {
                new.insert("", at: 0)
            }
            document.replace(first: document.count + 1, last: document.count, with: new)
        }

        let result = try parse(document, path: targetPath)
        guard result.itemCount == newIndex + 1, let added = result.snippets.first(where: { $0.id.index == newIndex }),
              MatchDraft(added) == MatchDraft(original), added.unknownKeys == original.unknownKeys,
              added.variables == original.variables
        else {
            throw .verificationFailed("The item could not be copied safely. Both files were left as they are.")
        }
        try checkOthersUnchanged(before: parsed, after: result, except: newIndex)
        return (document.data, newIndex)
    }

    // MARK: Append

    /// Adds a new match at the end of the `matches:` list and returns its position in the list.
    public static func append(_ draft: MatchDraft, to data: Data, path: String) throws(EditError) -> (data: Data, index: Int) {
        try validate(draft)
        var document = try SourceDocument(data)
        let parsed = try parse(document, path: path)
        let index = parsed.itemCount

        if parsed.itemCount > 0 {
            guard let last = parsed.itemRanges[parsed.itemCount - 1] else {
                throw .notEditable("New items can't be added to this file from the form. Edit the file as YAML.")
            }
            let indent = document.line(last.first).prefix { $0 == " " }.count
            var new = try newMatchLines(draft, indent: indent)
            if parsed.itemCount > 1, itemsAreSeparatedByBlankLines(parsed, document) {
                new.insert("", at: 0)
            }
            document.replace(first: last.last + 1, last: last.last, with: new)
        } else if let keyLine = parsed.matchesKeyLine {
            let line = document.line(keyLine)
            let rest = line.dropFirst("matches:".count).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("matches:"), ["", "[]", "~", "null"].contains(rest) else {
                throw .notEditable("New items can't be added to this file from the form. Edit the file as YAML.")
            }
            document.replace(first: keyLine, last: keyLine, with: ["matches:"] + (try newMatchLines(draft, indent: 2)))
        } else {
            var new = ["matches:"] + (try newMatchLines(draft, indent: 2))
            if document.count > 0, !document.isBlank(document.count) {
                new.insert("", at: 0)
            }
            document.replace(first: document.count + 1, last: document.count, with: new)
        }

        let result = try parse(document, path: path)
        guard result.itemCount == index + 1, let added = result.snippets.first(where: { $0.id.index == index }),
              MatchDraft(added) == draft
        else {
            throw .verificationFailed("The new item could not be written safely. The file was left as it is.")
        }
        try checkOthersUnchanged(before: parsed, after: result, except: index)
        return (document.data, index)
    }

    // MARK: New file

    /// The contents of a new match file that holds the given items, in order.
    public static func newFile(with drafts: [MatchDraft], path: String) throws(EditError) -> Data {
        guard !drafts.isEmpty else { return Data(emptyFileText.utf8) }
        var lines = ["matches:"]
        for draft in drafts {
            try validate(draft)
            lines += try newMatchLines(draft, indent: 2)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let result = try parse(try SourceDocument(data), path: path)
        let written = result.snippets.sorted { $0.id.index < $1.id.index }.map(MatchDraft.init)
        guard result.itemCount == drafts.count, written == drafts else {
            throw .verificationFailed("The items could not be written safely. Nothing was saved.")
        }
        return data
    }

    // MARK: Duplicate

    /// Copies the match at `index`, as written, to the line after it. Returns the copy's position in the list.
    public static func duplicate(matchAt index: Int, in data: Data, path: String) throws(EditError) -> (data: Data, index: Int) {
        var document = try SourceDocument(data)
        let parsed = try parse(document, path: path)
        guard let range = parsed.itemRanges[index], let original = parsed.snippets.first(where: { $0.id.index == index }),
              parsed.layouts[index] != nil
        else {
            throw .notEditable("This item can't be duplicated from the form. Edit the file as YAML.")
        }
        var copy = (range.first...range.last).map { document.line($0) }
        if range.first > 1, document.isBlank(range.first - 1) || parsed.leadingComments[index] != nil,
           itemsAreSeparatedByBlankLines(parsed, document) || parsed.itemCount == 1 {
            copy.insert("", at: 0)
        }
        document.replace(first: range.last + 1, last: range.last, with: copy)

        let result = try parse(document, path: path)
        guard result.snippets.count == parsed.snippets.count + 1,
              let added = result.snippets.first(where: { $0.id.index == index + 1 }),
              added.source == original.source
        else {
            throw .verificationFailed("The copy could not be written safely. The file was left as it is.")
        }
        return (document.data, index + 1)
    }

    // MARK: Delete

    /// Removes the match at `index`, along with the comment lines directly above it.
    public static func delete(matchAt index: Int, in data: Data, path: String) throws(EditError) -> Data {
        var document = try SourceDocument(data)
        let parsed = try parse(document, path: path)
        guard let range = parsed.itemRanges[index], parsed.snippets.contains(where: { $0.id.index == index }) else {
            throw .notEditable("This item can't be removed from the form. Edit the file as YAML.")
        }
        let first = parsed.leadingComments[index]?.first ?? range.first
        var last = range.last

        // Don't leave two blank lines where the item was.
        let blankAbove = first == 1 || document.isBlank(first - 1)
        if last < document.count, document.isBlank(last + 1), blankAbove {
            last += 1
        }
        document.replace(first: first, last: last, with: [])

        if parsed.itemCount == 1, let keyLine = parsed.matchesKeyLine, keyLine < first,
           document.line(keyLine).trimmingCharacters(in: .whitespaces) == "matches:" {
            // A bare "matches:" would read as null; an empty list says what is meant.
            document.replace(first: keyLine, last: keyLine, with: ["matches: []"])
        }

        let result = try parse(document, path: path)
        guard result.snippets.count == parsed.snippets.count - 1 else {
            throw .verificationFailed("The item could not be removed safely. The file was left as it is.")
        }
        let remaining = parsed.snippets.filter { $0.id.index != index }.map(\.source)
        guard result.snippets.map(\.source) == remaining else {
            throw .verificationFailed("The item could not be removed safely. The file was left as it is.")
        }
        return document.data
    }

    // MARK: Global variables

    /// Replaces the file's `global_vars:` list. An entry that is the same as before keeps its lines, and
    /// nothing outside the list changes.
    public static func setGlobalVariables(_ variables: [SnippetVariable], in data: Data, path: String) throws(EditError) -> Data {
        var seen = Set<String>()
        for variable in variables {
            guard MatchDraft.isValidName(variable.name) else {
                throw .invalidDraft("A variable name may contain only letters, numbers and underscores.")
            }
            guard seen.insert(variable.name).inserted else {
                throw .invalidDraft("Two variables are named \(variable.name).")
            }
        }
        let parsed = try parse(try SourceDocument(data), path: path)
        guard parsed.globalVariablesAreComplete else {
            throw .notEditable("The global variables of this file are written in a way the app can't change. Edit the file as YAML.")
        }
        guard parsed.globalVariableList != variables else { return data }

        var lines: [String]?
        if !variables.isEmpty {
            let existing = try ConfigFileEditor.lines(ofKey: "global_vars", in: data).map { (parsed.globalVariableList, $0) }
            lines = try YAMLEmitter.variableListLines(key: "global_vars", variables: variables, old: existing, indent: 0)
        }
        let updated = try ConfigFileEditor.set("global_vars", lines: lines, in: data, before: "matches")

        let result = try parse(try SourceDocument(updated), path: path)
        guard result.globalVariableList == variables, result.snippets.map(\.source) == parsed.snippets.map(\.source),
              result.imports == parsed.imports
        else {
            throw .verificationFailed("The change could not be written safely. The file was left as it is.")
        }
        return updated
    }

    // MARK: YAML editing

    /// Replaces the lines of the match at `index` with text the user wrote.
    public static func replaceSource(ofMatchAt index: Int, with yaml: String, in data: Data, path: String) throws(EditError) -> Data {
        var document = try SourceDocument(data)
        let parsed = try parse(document, path: path)
        guard let range = parsed.itemRanges[index] else {
            throw .notEditable("The lines of this item could not be determined. Edit the whole file instead.")
        }
        var lines = yaml.components(separatedBy: .newlines)
        while lines.last?.allSatisfy(\.isWhitespace) == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            throw .invalidYAML(line: nil, message: "The item is empty. Delete it instead.")
        }
        document.replace(first: range.first, last: range.last, with: lines)
        _ = try parse(document, path: path)
        return document.data
    }

    /// Checks text that replaces a whole match file.
    public static func validate(fileText text: String, path: String) throws(EditError) {
        do {
            _ = try MatchFileParser.parse(text, path: path)
        } catch let error as MatchFileError {
            throw .invalidYAML(line: error.line, message: error.message)
        } catch {
            throw .invalidYAML(line: nil, message: error.localizedDescription)
        }
    }

    /// The text of an empty match file.
    public static let emptyFileText = "matches: []\n"

    // MARK: Pieces

    /// One key of a match: the lines of its value, and any comment or blank lines that follow it.
    private struct Chunk {
        var name: String
        /// The first line starts at the key, without indentation. The others are whole lines.
        var core: [String]
        var trailing: [String] = []
    }

    private static func chunks(of layout: MatchLayout, in document: SourceDocument) -> [Chunk] {
        let keyIndent = layout.indent + 2
        var chunks: [Chunk] = []
        for (position, key) in layout.keys.enumerated() {
            let last = position + 1 < layout.keys.count ? layout.keys[position + 1].line - 1 : layout.range.last
            var coreEnd = last
            // Comment and blank lines at the key's own depth sit between keys; deeper ones belong to the value.
            while coreEnd > key.line {
                let line = document.line(coreEnd)
                let depth = line.prefix { $0 == " " }.count
                let content = line.drop { $0 == " " || $0 == "\t" }
                if content.isEmpty || (content.first == "#" && depth <= keyIndent) {
                    coreEnd -= 1
                } else {
                    break
                }
            }
            var core = (key.line...coreEnd).map { document.line($0) }
            core[0] = String(core[0].dropFirst(keyIndent))
            let trailing = coreEnd < last ? ((coreEnd + 1)...last).map { document.line($0) } : []
            chunks.append(Chunk(name: key.name, core: core, trailing: trailing))
        }
        return chunks
    }

    private static func lines(of chunks: [Chunk], indent: Int) -> [String] {
        let padding = String(repeating: " ", count: indent)
        var lines: [String] = []
        for (position, chunk) in chunks.enumerated() {
            lines.append(padding + (position == 0 ? "- " : "  ") + chunk.core[0])
            lines += chunk.core.dropFirst()
            lines += chunk.trailing
        }
        // A match never ends with blank lines of its own.
        while lines.count > 1, lines.last?.allSatisfy({ $0 == " " }) == true {
            lines.removeLast()
        }
        return lines
    }

    /// Writes `trigger:` for one trigger or `triggers:` for several, where the old key was.
    private static func setTriggers(
        _ triggers: [String], in chunks: inout [Chunk], keyIndent: Int, style: ScalarStyle?
    ) throws(EditError) {
        let position = chunks.firstIndex { $0.name == "trigger" || $0.name == "triggers" } ?? 0
        let comments = chunks.filter { $0.name == "trigger" || $0.name == "triggers" }.flatMap(\.trailing)
        chunks.removeAll { $0.name == "trigger" || $0.name == "triggers" }
        var chunk: Chunk
        if triggers.count == 1 {
            chunk = Chunk(name: "trigger", core: try YAMLEmitter.lines(
                key: "trigger", string: triggers[0], indent: keyIndent, prefer: style
            ))
        } else {
            chunk = Chunk(name: "triggers", core: try YAMLEmitter.lines(
                key: "triggers", strings: triggers, indent: keyIndent
            ))
        }
        chunk.trailing = comments
        chunks.insert(chunk, at: min(position, chunks.count))
    }

    /// Replaces, adds or (with nil) removes a key.
    private static func set(_ key: String, _ core: [String]?, in chunks: inout [Chunk]) {
        if let position = chunks.firstIndex(where: { $0.name == key }) {
            if let core {
                chunks[position].core = core
            } else {
                let removed = chunks.remove(at: position)
                let comments = removed.trailing.filter { !$0.allSatisfy { $0 == " " } }
                if position > 0 {
                    chunks[position - 1].trailing += comments
                }
            }
            return
        }
        guard let core else { return }
        let rank = keyOrder.firstIndex(of: key) ?? keyOrder.count
        var position = 0
        for (index, chunk) in chunks.enumerated() {
            if let other = keyOrder.firstIndex(of: chunk.name), other < rank {
                position = index + 1
            }
        }
        chunks.insert(Chunk(name: key, core: core), at: position)
    }

    private static func newMatchLines(_ draft: MatchDraft, indent: Int) throws(EditError) -> [String] {
        let keyIndent = indent + 2
        var chunks: [Chunk] = []
        if let regex = draft.regex {
            chunks.append(Chunk(name: "regex", core: try YAMLEmitter.lines(key: "regex", string: regex, indent: keyIndent)))
        } else if draft.triggers.count == 1 {
            chunks.append(Chunk(name: "trigger", core: try YAMLEmitter.lines(
                key: "trigger", string: draft.triggers[0], indent: keyIndent
            )))
        } else {
            chunks.append(Chunk(name: "triggers", core: try YAMLEmitter.lines(
                key: "triggers", strings: draft.triggers, indent: keyIndent
            )))
        }
        let key = expansionKey(draft.expansion)
        chunks.append(Chunk(name: key, core: try YAMLEmitter.lines(key: key, string: draft.body, indent: keyIndent)))
        if !draft.label.isEmpty {
            chunks.append(Chunk(name: "label", core: try YAMLEmitter.lines(key: "label", string: draft.label, indent: keyIndent)))
        }
        if !draft.searchTerms.isEmpty {
            chunks.append(Chunk(name: "search_terms", core: try YAMLEmitter.lines(
                key: "search_terms", strings: draft.searchTerms, indent: keyIndent
            )))
        }
        for (key, _, isOn) in flags(SnippetOptions(), draft.options) where isOn {
            chunks.append(Chunk(name: key, core: YAMLEmitter.lines(key: key, bool: true)))
        }
        if let style = draft.options.uppercaseStyle {
            chunks.append(Chunk(name: "uppercase_style", core: ["uppercase_style: \(style.rawValue)"]))
        }
        if let mode = draft.options.forceMode {
            chunks.append(Chunk(name: "force_mode", core: ["force_mode: \(mode.rawValue)"]))
        }
        if !draft.formFields.isEmpty {
            set("form_fields", try YAMLEmitter.lines(key: "form_fields", value: .map(draft.formFields), indent: keyIndent), in: &chunks)
        }
        if !draft.variables.isEmpty {
            chunks.append(Chunk(name: "vars", core: try YAMLEmitter.variableListLines(
                key: "vars", variables: draft.variables, old: nil, indent: keyIndent
            )))
        }
        return lines(of: chunks, indent: indent)
    }

    private static func flags(_ old: SnippetOptions, _ new: SnippetOptions) -> [(String, Bool, Bool)] {
        [
            ("word", old.word, new.word),
            ("left_word", old.leftWord, new.leftWord),
            ("right_word", old.rightWord, new.rightWord),
            ("propagate_case", old.propagateCase, new.propagateCase),
            ("paragraph", old.paragraph, new.paragraph),
        ]
    }

    private static func expansionKey(_ expansion: Expansion) -> String {
        switch expansion {
        case .text, .missing: return "replace"
        case .markdown: return "markdown"
        case .html: return "html"
        case .image: return "image_path"
        case .form: return "form"
        }
    }

    private static func sameKind(_ lhs: Expansion, _ rhs: Expansion) -> Bool {
        if case .missing = lhs, case .text = rhs { return true }
        return expansionKey(lhs) == expansionKey(rhs)
    }

    private static func itemsAreSeparatedByBlankLines(_ parsed: ParsedMatchFile, _ document: SourceDocument) -> Bool {
        let last = parsed.itemCount - 1
        guard let range = parsed.itemRanges[last] else { return false }
        let first = parsed.leadingComments[last]?.first ?? range.first
        return first > 1 && document.isBlank(first - 1)
    }

    private static func validate(_ draft: MatchDraft) throws(EditError) {
        if let problem = draft.blockingProblem {
            throw .invalidDraft(problem)
        }
    }

    private static func parse(_ document: SourceDocument, path: String) throws(EditError) -> ParsedMatchFile {
        do {
            return try MatchFileParser.parse(document.text, path: path)
        } catch let error as MatchFileError {
            throw .invalidYAML(line: error.line, message: error.message)
        } catch {
            throw .invalidYAML(line: nil, message: error.localizedDescription)
        }
    }

    private static func checkOthersUnchanged(before: ParsedMatchFile, after: ParsedMatchFile, except index: Int) throws(EditError) {
        let old = before.snippets.filter { $0.id.index != index }.map(\.source)
        let new = after.snippets.filter { $0.id.index != index }.map(\.source)
        guard old == new, before.imports == after.imports,
              before.globalVariableNames == after.globalVariableNames
        else {
            throw .verificationFailed("The change would have altered other items. The file was left as it is.")
        }
    }
}
