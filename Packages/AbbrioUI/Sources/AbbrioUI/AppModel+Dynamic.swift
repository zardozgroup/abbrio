public import Foundation
public import ConfigStore
public import EspansoCLI
public import SnippetModel

/// The language of a script kept in the config folder's `scripts` folder. Both run through `osascript`.
public nonisolated enum ScriptLanguage: String, CaseIterable, Identifiable, Sendable {
    case appleScript = "AppleScript"
    case javaScript = "JavaScript"

    public var id: Self { self }

    var fileExtension: String {
        switch self {
        case .appleScript: return "applescript"
        case .javaScript: return "js"
        }
    }

    /// The arguments in front of the script's path.
    var interpreter: [String] {
        switch self {
        case .appleScript: return ["osascript"]
        case .javaScript: return ["osascript", "-l", "JavaScript"]
        }
    }
}

/// A trigger another item can insert, for the Insert Abbreviation picker.
public nonisolated struct TriggerChoice: Identifiable, Hashable, Sendable {
    public var trigger: String
    public var detail: String
    public var setName: String

    public var id: String { setName + "\u{1F}" + trigger }
}

/// Dynamic content of the item being edited: variables, form fields, the expansion's type, pictures and
/// scripts.
extension AppModel {
    /// Where scripts written by the app are kept, relative to the config folder.
    nonisolated static let scriptsFolder = "scripts"
    /// Where pictures copied by the app are kept, relative to the config folder.
    nonisolated static let imagesFolder = "images"

    // MARK: Text

    /// Sets the expansion's text. A variable or field whose last reference left the text goes with it, and
    /// comes back when the reference does.
    public func setBody(_ text: String) {
        updateDraft { draft in
            contentMemory.record(draft)
            let old = draft.body
            draft.body = text
            draft.reconcile(afterBodyChangedFrom: old)
            contentMemory.restore(into: &draft)
        }
    }

    /// The global variables of the set that holds the selected item.
    public var editingGlobalVariables: [SnippetVariable] {
        guard let id = selectedSnippetID else { return [] }
        return set(containing: id)?.globalVariableList ?? []
    }

    /// A name no variable of the item, and no global variable of its set, has yet.
    public func uniqueVariableName(_ base: String) -> String {
        (draft ?? MatchDraft()).uniqueName(base, alsoTaken: Set(editingGlobalVariables.map(\.name)))
    }

    // MARK: Variables

    /// Adds a variable to the item and returns the text that refers to it, for the text box to insert.
    public func addVariable(_ variable: SnippetVariable) -> String? {
        guard draft != nil, formLockReason == nil else { return nil }
        var token: String?
        updateDraft { token = $0.addVariable(variable) }
        return token
    }

    public func updateVariable(named name: String, to variable: SnippetVariable) {
        updateDraft { $0.updateVariable(named: name, to: variable) }
        commitDraft()
    }

    public func removeVariable(named name: String) {
        updateDraft { $0.removeVariable(named: name) }
        commitDraft()
    }

    /// Adds a field to the item's form and returns the text that refers to it.
    public func addFormField(_ field: FormField) -> String? {
        guard draft != nil, formLockReason == nil else { return nil }
        var token: String?
        updateDraft { token = $0.addFormField(field) }
        return token
    }

    public func updateFormField(named name: String, to field: FormField) {
        updateDraft { $0.updateFormField(named: name, to: field) }
        commitDraft()
    }

    public func removeFormField(named name: String) {
        updateDraft { $0.removeFormField(named: name) }
        commitDraft()
    }

    /// Every trigger in a switched-on set, for an item to insert another item's expansion.
    public var triggerChoices: [TriggerChoice] {
        var choices: [TriggerChoice] = []
        let preview = ExpansionPreview()
        for set in sets where set.isEnabled {
            for snippet in set.snippets where !snippet.isRegex && snippet.id != selectedSnippetID {
                for trigger in snippet.triggers where !trigger.isEmpty {
                    choices.append(TriggerChoice(
                        trigger: trigger, detail: snippet.label ?? preview.text(for: snippet), setName: set.name
                    ))
                }
            }
        }
        return choices
    }

    // MARK: Type

    /// True when switching the item to a picture would put text or variables aside.
    public var switchingToPictureDiscardsContent: Bool {
        guard let draft, draft.expansion.kind != .picture else { return false }
        return !draft.body.isEmpty || !draft.variables.isEmpty
    }

    /// Changes the expansion's type.
    ///
    /// Between Text, Markdown and HTML the text stays exactly as it is and only its key changes. A switch to
    /// Picture puts the text and its variables aside; switching back while the item is still selected
    /// restores them. Only what belongs to the chosen type is saved.
    public func setKind(_ kind: ExpansionKind) {
        guard let draft, formLockReason == nil, draft.expansion.kind != kind else { return }
        if kind == .picture {
            textStash = (draft.expansion, draft.variables, draft.formFields)
            let path = pictureStash ?? ""
            updateDraft {
                $0.expansion = .image(path: path)
                $0.variables = []
                $0.formFields = []
            }
        } else if draft.expansion.kind == .picture {
            if !draft.body.isEmpty { pictureStash = draft.body }
            let stash = textStash
            updateDraft {
                $0.expansion = stash?.expansion ?? .text("")
                $0.variables = stash?.variables ?? []
                $0.formFields = stash?.formFields ?? []
                $0.setTextKind(kind)
            }
        } else {
            updateDraft { $0.setTextKind(kind) }
        }
        commitDraft()
    }

    // MARK: Pictures

    /// The file a picture item points at.
    public func pictureURL(forPath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        var resolved = path
        if let folder = configFolder?.path {
            resolved = resolved.replacingOccurrences(of: "$CONFIG", with: folder)
                .replacingOccurrences(of: "%CONFIG%", with: folder)
        }
        return URL(fileURLWithPath: (resolved as NSString).expandingTildeInPath)
    }

    /// Makes a picture the item's expansion.
    ///
    /// The file is checked first, off the main actor: it must be an ordinary file of at most 32 MB holding a
    /// picture of at most 40 million pixels. A file that fails is named in an alert and nothing changes.
    /// The checked bytes are copied into the config folder's `images` folder under a name nothing else
    /// there uses, and the item points at the copy, so it keeps working when the original is moved. With
    /// `referencingOriginal`, nothing is copied and the item points at the file where it is. The item is
    /// saved only after the copy is complete, and not at all when another item was selected meanwhile.
    @discardableResult
    public func setPicture(from url: URL, referencingOriginal: Bool) async -> Bool {
        guard draft != nil, formLockReason == nil else { return false }
        let selection = selectedSnippetID
        let picture: CheckedPicture
        do {
            picture = try await PictureLoader.check(url)
        } catch {
            alertMessage = "\(url.lastPathComponent) can't be used as a picture: it \(error.reason)."
            return false
        }
        guard selectedSnippetID == selection, draft != nil, formLockReason == nil else { return false }
        var path = url.path
        if !referencingOriginal {
            guard let folder = configFolder else { return false }
            do {
                path = "$CONFIG/" + Self.imagesFolder + "/" + (try Self.copyPicture(url, contents: picture.contents, into: folder))
            } catch {
                alertMessage = "The picture could not be copied: \(error.localizedDescription)"
                return false
            }
        }
        if draft?.expansion.kind != .picture {
            setKind(.picture)
        }
        updateDraft {
            $0.expansion = .image(path: path)
            $0.variables = []
            $0.formFields = []
        }
        return commitDraft()
    }

    /// Writes a picture's checked bytes into the images folder and returns the file's name, which is made
    /// from `source`'s name. A file already there is never replaced: the same picture is used again, and a
    /// different one gets a numbered name.
    nonisolated static func copyPicture(_ source: URL, contents: Data, into configFolder: URL) throws -> String {
        let manager = FileManager.default
        let folder = configFolder.appendingPathComponent(imagesFolder, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let original = source.deletingPathExtension().lastPathComponent
        var stem = String(original.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        if stem.isEmpty { stem = "picture" }
        let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension.lowercased()

        var number = 1
        while true {
            let name = (number == 1 ? stem : "\(stem)-\(number)") + suffix
            let target = folder.appendingPathComponent(name)
            if !manager.fileExists(atPath: target.path) {
                // Writing without overwriting fails when the name was taken in the meantime, so nothing is
                // ever replaced; the file that took it is then compared like any other.
                do {
                    try contents.write(to: target, options: .withoutOverwriting)
                    return name
                } catch CocoaError.fileWriteFileExists {
                } catch {
                    throw error
                }
            }
            // An existing file is read with the same limits, so a pipe left there can't stall the copy.
            if (try? PictureLoader.contents(of: target)) == contents {
                return name
            }
            number += 1
        }
    }

    // MARK: Scripts

    /// The language and file of a script variable the app can edit: one that runs `osascript` on a file in
    /// the config folder's `scripts` folder.
    public func scriptFile(of variable: SnippetVariable) -> (language: ScriptLanguage, path: String)? {
        guard variable.type == "script", let items = variable.params["args"]?.list else { return nil }
        let arguments = items.compactMap(\.text)
        guard arguments.count == items.count, let last = arguments.last else { return nil }
        let prefix = "%CONFIG%/" + Self.scriptsFolder + "/"
        guard last.hasPrefix(prefix), !last.dropFirst(prefix.count).contains("/"), !last.contains("..") else { return nil }
        let path = Self.scriptsFolder + "/" + last.dropFirst(prefix.count)
        for language in ScriptLanguage.allCases where Array(arguments.dropLast()) == language.interpreter {
            return (language, path)
        }
        return nil
    }

    /// The text of a script variable's file.
    public func scriptCode(of variable: SnippetVariable) -> String? {
        guard let file = scriptFile(of: variable), let data = try? writer?.read(file.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes a script to the `scripts` folder and returns the variable that runs it. A file the variable
    /// already points at is updated, with a backup; otherwise a new file is made and none is replaced.
    public func saveScript(_ code: String, language: ScriptLanguage, for variable: SnippetVariable) -> SnippetVariable? {
        guard let writer else { return nil }
        // The name becomes part of a file name, so a name from a hand-written or copied file is checked here
        // as well as in the sheet.
        guard MatchDraft.isValidName(variable.name) else {
            alertMessage = "\u{201C}\(variable.name)\u{201D} can't be used as a script name. Use only letters, numbers and underscores."
            return nil
        }
        var path: String
        var current: Data?
        if let existing = scriptFile(of: variable), existing.language == language {
            path = existing.path
            current = try? writer.read(path)
        } else {
            var number = 1
            repeat {
                let name = (number == 1 ? variable.name : "\(variable.name)-\(number)") + "." + language.fileExtension
                path = Self.scriptsFolder + "/" + name
                number += 1
            } while FileManager.default.fileExists(atPath: writer.url(for: path).path)
        }
        do {
            try FileManager.default.createDirectory(
                at: writer.url(for: Self.scriptsFolder), withIntermediateDirectories: true
            )
            let data = Data(code.utf8)
            if data != current {
                try writer.write(data, to: path, replacing: current)
            }
        } catch {
            alertMessage = "The script could not be saved: \(error.localizedDescription)"
            return nil
        }
        var result = variable
        result.type = "script"
        result.params["args"] = .list((language.interpreter + ["%CONFIG%/" + path]).map(ParamValue.string))
        return result
    }

    /// Runs a script the way the variable would, and returns what it printed or why it failed.
    public func testScript(_ code: String, language: ScriptLanguage) async -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("abbrio-test-\(UUID().uuidString).\(language.fileExtension)")
        do {
            try Data(code.utf8).write(to: file)
        } catch {
            return "The script could not be written: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = Array(language.interpreter.dropFirst()) + [file.path]
        return await run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments)
    }

    /// Runs a shell command in the user's shell, as Espanso does on a Mac.
    public func testShellCommand(_ command: String) async -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh"
        return await run(URL(fileURLWithPath: shell), ["-c", command])
    }

    private func run(_ executable: URL, _ arguments: [String]) async -> String {
        var environment = ProcessInfo.processInfo.environment
        if let folder = configFolder?.path { environment["CONFIG"] = folder }
        do {
            let result = try await runner.run(executable, arguments: arguments, environment: environment, timeout: 10)
            let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.succeeded { return output.isEmpty ? "(no output)" : output }
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Failed with exit code \(result.exitCode)" + (message.isEmpty ? "" : ": " + message)
        } catch CommandError.timedOut {
            return "Stopped after 10 seconds without finishing."
        } catch {
            return "Could not be run: \(error)"
        }
    }

    // MARK: Global variables

    /// Replaces the `global_vars:` list of a set's file. Returns a message when it could not be done.
    @discardableResult
    public func setGlobalVariables(_ variables: [SnippetVariable], inSet id: String) -> String? {
        guard let set = sets.first(where: { $0.id == id }), !set.isLocked, let file = set.files.first else {
            return "This set can't be changed."
        }
        guard commitDraft() else { return "The item being edited could not be saved first." }
        let selection = selectedSnippetID
        return change(file.path, named: "Edit Global Variables") { data throws(EditError) in
            (try MatchFileEditor.setGlobalVariables(variables, in: data, path: file.path), selection)
        }
    }
}
