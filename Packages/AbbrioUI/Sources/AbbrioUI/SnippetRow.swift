import Foundation
public import SnippetModel

/// The small marks in the Options column.
public nonisolated enum OptionGlyph: Hashable, Sendable {
    case caseAffectsExpansion
    case wordBreak
    case dynamicContent
    case form
    case picture
    case script
    case regex
    case markdown
    case html
    case duplicateTrigger

    /// The explanation shown when the pointer rests on the mark.
    public var help: String {
        switch self {
        case .caseAffectsExpansion: return "Case affects expansion"
        case .wordBreak: return "Expands at word break"
        case .dynamicContent: return "Contains dynamic content"
        case .form: return "Asks for input with a form"
        case .picture: return "Inserts a picture"
        case .script: return "Runs a script or shell command"
        case .regex: return "Regular expression"
        case .markdown: return "Markdown expansion"
        case .html: return "HTML expansion"
        case .duplicateTrigger: return "Espanso will ask which one to use."
        }
    }
}

/// One line of the abbreviation list.
public nonisolated struct SnippetRow: Identifiable, Hashable, Sendable {
    public var id: Snippet.ID
    public var abbreviation: String
    /// The table label when there are aliases. Sorting uses the first trigger in `abbreviation`.
    let abbreviationWithAliases: String?
    public var expansion: String
    public var description: String
    public var glyphs: [OptionGlyph]
    /// Name of the set the match belongs to.
    public var setName: String

    public init(
        snippet: Snippet, setName: String, isDuplicate: Bool, preview: ExpansionPreview, displayAliases: [String]? = nil
    ) {
        id = snippet.id
        abbreviation = snippet.abbreviation
        let aliases = displayAliases?[...] ?? snippet.triggers.dropFirst()
        abbreviationWithAliases = snippet.isRegex || aliases.isEmpty
            ? nil : ([snippet.abbreviation] + aliases).joined(separator: ", ")
        expansion = preview.text(for: snippet)
        description = snippet.label ?? ""
        self.setName = setName

        var glyphs: [OptionGlyph] = []
        if snippet.isRegex { glyphs.append(.regex) }
        switch snippet.expansion {
        case .markdown: glyphs.append(.markdown)
        case .html: glyphs.append(.html)
        case .image: glyphs.append(.picture)
        default: break
        }
        if snippet.hasDynamicContent { glyphs.append(.dynamicContent) }
        if snippet.hasForm { glyphs.append(.form) }
        if snippet.hasScript { glyphs.append(.script) }
        if snippet.options.propagateCase { glyphs.append(.caseAffectsExpansion) }
        if snippet.options.word { glyphs.append(.wordBreak) }
        if isDuplicate { glyphs.append(.duplicateTrigger) }
        self.glyphs = glyphs
    }
}

nonisolated extension Snippet {
    /// The choice shown in the Case pop-up, taken from the match's flags.
    var caseChoice: String {
        options.propagateCase ? "Case affects expansion" : "Case must match"
    }

    /// The choice shown in the Expand pop-up, taken from the match's flags.
    var expandChoice: String {
        if options.word { return "At word break" }
        if options.leftWord { return "At word start only" }
        if options.rightWord { return "At word end only" }
        return "On match"
    }

    var insertUsingChoice: String {
        switch options.forceMode {
        case .keys: return "Keystrokes"
        case .clipboard: return "Clipboard"
        case nil: return "Automatic"
        }
    }

    /// The line under the expansion that shows what each letter case of the trigger produces.
    var casePreview: String? {
        guard options.propagateCase, case .text(let text) = expansion, let trigger = triggers.first,
              variables.isEmpty, !text.contains("\n"), !trigger.isEmpty, !text.isEmpty
        else { return nil }
        let capitalizedTrigger = trigger.prefix(1).uppercased() + trigger.dropFirst()
        let capitalizedText: String
        if options.uppercaseStyle == .capitalizeWords {
            capitalizedText = text.capitalized
        } else {
            capitalizedText = text.prefix(1).uppercased() + text.dropFirst()
        }
        return "Case preview: \(trigger) → \(text) · \(capitalizedTrigger) → \(capitalizedText) · "
            + "\(trigger.uppercased()) → \(text.uppercased())"
    }
}
