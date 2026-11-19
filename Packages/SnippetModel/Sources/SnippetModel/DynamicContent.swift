import Foundation

/// One piece of an expansion's text: plain text, the cursor marker, or a reference to a variable or field.
public struct ExpansionPiece: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text
        /// `$|$`, where the cursor ends up.
        case cursor
        /// `{{name}}`, or `{{form.field}}` for a field of a form variable.
        case variable(name: String, field: String?)
        /// `[[name]]`, a field of a match written with the short `form:` key.
        case field(String)
    }

    public var kind: Kind
    /// The piece exactly as it is written in the text.
    public var source: String

    public init(kind: Kind, source: String) {
        self.kind = kind
        self.source = source
    }

    public var isText: Bool { kind == .text }

    /// Splits an expansion into its pieces. Joining the pieces' `source` gives the text back.
    ///
    /// - Parameter isShortForm: True for the text of a `form:` key, where `[[name]]` is a field.
    public static func pieces(of text: String, isShortForm: Bool) -> [ExpansionPiece] {
        var pieces: [ExpansionPiece] = []
        var position = text.startIndex
        for match in text.matches(of: pattern) {
            let source = String(text[match.range])
            let kind: Kind
            if source == "$|$" {
                kind = .cursor
            } else if let name = match.output.1 {
                kind = .variable(name: String(name), field: match.output.2.map(String.init))
            } else if let name = match.output.3, isShortForm {
                kind = .field(String(name))
            } else {
                continue
            }
            if position < match.range.lowerBound {
                pieces.append(ExpansionPiece(kind: .text, source: String(text[position..<match.range.lowerBound])))
            }
            pieces.append(ExpansionPiece(kind: kind, source: source))
            position = match.range.upperBound
        }
        if position < text.endIndex {
            pieces.append(ExpansionPiece(kind: .text, source: String(text[position...])))
        }
        return pieces
    }

    private nonisolated(unsafe) static let pattern =
        /\$\|\$|\{\{\s*([A-Za-z0-9_]+)(?:\.([A-Za-z0-9_]+))?\s*\}\}|\[\[\s*([A-Za-z0-9_]+)\s*\]\]/
}

/// One field of a form: an input field or a pop-up menu.
public struct FormField: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// A text box.
        case text
        /// A pop-up menu.
        case choice
        /// A list box, where several values can be picked on Espanso 2.4 and later.
        case list
    }

    public var name: String
    /// The words in front of the field in the form. Nil when the form's layout doesn't give the field a line
    /// of its own, and for the short `form:` syntax, where the whole text is the layout.
    public var label: String?
    public var kind: Kind
    public var isMultiline: Bool
    public var defaultValue: String
    public var values: [String]
    /// What joins the chosen values of a list. Nil leaves Espanso's own separator.
    public var separator: String?

    public init(
        name: String, label: String? = nil, kind: Kind = .text, isMultiline: Bool = false,
        defaultValue: String = "", values: [String] = [], separator: String? = nil
    ) {
        self.name = name
        self.label = label
        self.kind = kind
        self.isMultiline = isMultiline
        self.defaultValue = defaultValue
        self.values = values
        self.separator = separator
    }

    /// Reads a field from its properties, as written under `fields:` or `form_fields:`.
    public init(name: String, label: String?, properties: [ParamEntry]) {
        self.init(name: name, label: label)
        kind = properties["type"]?.text.flatMap(Kind.init(rawValue:)) ?? .text
        isMultiline = properties["multiline"]?.bool ?? false
        defaultValue = properties["default"]?.text ?? ""
        values = Self.values(properties["values"])
        separator = properties["separator"]?.text
    }

    private static func values(_ value: ParamValue?) -> [String] {
        switch value {
        case .list(let items)?:
            return items.compactMap(\.text)
        case .string(let text)?:
            // Espanso also accepts one value per line.
            return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    /// Writes the field into its properties. Properties the app doesn't know stay as they are.
    public func apply(to properties: inout [ParamEntry]) {
        if kind == .text {
            if properties["type"]?.text != "text" { properties["type"] = nil }
        } else {
            properties["type"] = .string(kind.rawValue)
        }
        properties["multiline"] = kind == .text && isMultiline ? .bool(true) : nil
        if kind == .text {
            properties["values"] = nil
        } else if Self.values(properties["values"]) != values {
            properties["values"] = .list(values.map(ParamValue.string))
        }
        if defaultValue.isEmpty {
            properties["default"] = nil
        } else if properties["default"]?.text != defaultValue {
            properties["default"] = .string(defaultValue)
        }
        properties["separator"] = kind == .list ? separator.map(ParamValue.string) : nil
    }

    /// The properties of a new field.
    public var properties: [ParamEntry] {
        var properties: [ParamEntry] = []
        apply(to: &properties)
        return properties
    }
}

/// The kind of expansion, as the type bar shows it.
public enum ExpansionKind: String, CaseIterable, Hashable, Sendable {
    case text = "Text"
    case markdown = "Markdown"
    case html = "HTML"
    case picture = "Picture"
}

extension Expansion {
    public var kind: ExpansionKind {
        switch self {
        case .text, .form, .missing: return .text
        case .markdown: return .markdown
        case .html: return .html
        case .image: return .picture
        }
    }
}

extension SnippetVariable {
    /// The start of the name a new variable of a type is given: `date1`, `clip1`.
    public static func baseName(forType type: String) -> String {
        switch type {
        case "clipboard": return "clip"
        case "match": return "abbr"
        case "echo": return "text"
        default: return type.isEmpty ? "var" : type
        }
    }

    /// The layout of a form variable.
    public var layout: String {
        get { params["layout"]?.text ?? "" }
        set { params["layout"] = .string(newValue) }
    }

    /// The names of the fields in a form variable's layout, in order.
    public var layoutFieldNames: [String] {
        ExpansionPiece.pieces(of: layout, isShortForm: true).compactMap {
            if case .field(let name) = $0.kind { return name }
            return nil
        }
    }

    /// The words in front of a field, when the field has a line of the layout to itself.
    func label(ofField name: String) -> String? {
        for line in layout.components(separatedBy: "\n") {
            let pieces = ExpansionPiece.pieces(of: line, isShortForm: true)
            guard pieces.contains(where: { $0.kind == .field(name) }) else { continue }
            guard pieces.count <= 2, pieces.last?.kind == .field(name) else { return nil }
            var label = pieces.count == 2 ? pieces[0].source.trimmingCharacters(in: .whitespaces) : ""
            if label.hasSuffix(":") { label.removeLast() }
            return label.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func layoutLine(label: String?, name: String) -> String {
        guard let label, !label.isEmpty else { return "[[\(name)]]" }
        return "\(label): [[\(name)]]"
    }

    /// Changes a field's line in the layout, or its name where the field shares a line.
    mutating func setLayout(ofField old: String, label: String?, name: String) {
        var lines = layout.components(separatedBy: "\n")
        for (position, line) in lines.enumerated() {
            let pieces = ExpansionPiece.pieces(of: line, isShortForm: true)
            guard pieces.contains(where: { $0.kind == .field(old) }) else { continue }
            if self.label(ofField: old) != nil, let label {
                lines[position] = Self.layoutLine(label: label, name: name)
            } else {
                lines[position] = pieces.map { $0.kind == .field(old) ? "[[\(name)]]" : $0.source }.joined()
            }
        }
        layout = lines.joined(separator: "\n")
    }

    mutating func removeFromLayout(field name: String) {
        var lines: [String] = []
        for line in layout.components(separatedBy: "\n") {
            let pieces = ExpansionPiece.pieces(of: line, isShortForm: true)
            guard pieces.contains(where: { $0.kind == .field(name) }) else {
                lines.append(line)
                continue
            }
            // A field with a line to itself takes the line with it.
            let others = pieces.filter { $0.kind != .field(name) }
            if others.contains(where: { !$0.isText }) {
                lines.append(others.map(\.source).joined())
            }
        }
        layout = lines.joined(separator: "\n")
    }

    /// The properties of a form variable's field.
    func properties(ofField name: String) -> [ParamEntry] {
        params["fields"]?.map?[name]?.map ?? []
    }

    mutating func setProperties(_ properties: [ParamEntry]?, ofField name: String) {
        var fields = params["fields"]?.map ?? []
        if let properties, !properties.isEmpty {
            fields[name] = .map(properties)
        } else {
            fields[name] = nil
        }
        params["fields"] = fields.isEmpty ? nil : .map(fields)
    }
}

// MARK: - Dynamic content of a draft

extension MatchDraft {
    /// True for a match written with the short `form:` key.
    public var isShortForm: Bool {
        if case .form = expansion { return true }
        return false
    }

    public var pieces: [ExpansionPiece] {
        ExpansionPiece.pieces(of: body, isShortForm: isShortForm)
    }

    public var hasCursor: Bool {
        pieces.contains { $0.kind == .cursor }
    }

    /// Where the match's form variable is in `variables`.
    public var formVariableIndex: Int? {
        variables.firstIndex { $0.type == "form" }
    }

    /// A name no variable or field of this match has yet: `date1`, `date2`.
    public func uniqueName(_ base: String, alsoTaken: Set<String> = []) -> String {
        var taken = alsoTaken
        taken.formUnion(variables.map(\.name))
        taken.formUnion(formFields.map(\.key))
        for variable in variables where variable.type == "form" {
            taken.formUnion(variable.layoutFieldNames)
        }
        for piece in pieces {
            if case .field(let name) = piece.kind { taken.insert(name) }
        }
        var number = 1
        while taken.contains(base + String(number)) { number += 1 }
        return base + String(number)
    }

    // MARK: Variables

    /// Adds a variable and returns the text that refers to it, `{{name}}`.
    ///
    /// A match written with the short `form:` key is first rewritten in the long form, because the short one
    /// has no place for other variables.
    @discardableResult
    public mutating func addVariable(_ variable: SnippetVariable) -> String {
        if isShortForm { convertToVerboseForm() }
        variables.append(variable)
        return "{{\(variable.name)}}"
    }

    /// Replaces a variable, following a change of its name through the text.
    public mutating func updateVariable(named old: String, to variable: SnippetVariable) {
        guard let position = variables.firstIndex(where: { $0.name == old }) else { return }
        variables[position] = variable
        guard old != variable.name else { return }
        body = pieces.map { piece in
            if case .variable(old, let field) = piece.kind {
                return "{{" + variable.name + (field.map { "." + $0 } ?? "") + "}}"
            }
            return piece.source
        }.joined()
    }

    /// Removes a variable and every reference to it in the text.
    public mutating func removeVariable(named name: String) {
        variables.removeAll { $0.name == name }
        body = pieces.filter { piece in
            if case .variable(name, _) = piece.kind { return false }
            return true
        }.map(\.source).joined()
    }

    /// True when another variable uses this one, in its parameters or as a dependency.
    func isUsedByAnotherVariable(_ name: String) -> Bool {
        let environmentName = "ESPANSO_" + name.uppercased()
        for variable in variables where variable.name != name {
            let texts = variable.params.flatMap(\.value.allText) + variable.extras.flatMap(\.value.allText)
            for text in texts {
                if text == name || text.contains(environmentName) { return true }
                let references = ExpansionPiece.pieces(of: text, isShortForm: false)
                if references.contains(where: { if case .variable(name, _) = $0.kind { true } else { false } }) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Form fields

    /// The names of the form's fields, in the order the form shows them.
    public var formFieldNames: [String] {
        if isShortForm {
            var names: [String] = []
            for piece in pieces {
                if case .field(let name) = piece.kind, !names.contains(name) { names.append(name) }
            }
            return names
        }
        guard let index = formVariableIndex else { return [] }
        return variables[index].layoutFieldNames
    }

    public func formField(named name: String) -> FormField? {
        guard formFieldNames.contains(name) else { return nil }
        if isShortForm {
            return FormField(name: name, label: nil, properties: formFields[name]?.map ?? [])
        }
        guard let index = formVariableIndex else { return nil }
        let variable = variables[index]
        return FormField(name: name, label: variable.label(ofField: name), properties: variable.properties(ofField: name))
    }

    public var formFieldList: [FormField] {
        formFieldNames.compactMap(formField(named:))
    }

    /// Adds a field to the match's form, creating the form when there is none, and returns the text that
    /// refers to the field.
    ///
    /// A match that already uses the short `form:` key keeps it. A plain match gets a form variable whose
    /// layout holds only the labelled fields.
    public mutating func addFormField(_ field: FormField) -> String {
        if isShortForm {
            let properties = field.properties
            if !properties.isEmpty { formFields[field.name] = .map(properties) }
            return "[[\(field.name)]]"
        }
        let index: Int
        if let existing = formVariableIndex {
            index = existing
        } else {
            variables.append(SnippetVariable(name: uniqueName("form"), type: "form", params: [ParamEntry("layout", .string(""))]))
            index = variables.count - 1
        }
        let line = SnippetVariable.layoutLine(label: field.label ?? ExpansionPreview.humanized(field.name), name: field.name)
        variables[index].layout = variables[index].layout.isEmpty ? line : variables[index].layout + "\n" + line
        variables[index].setProperties(field.properties, ofField: field.name)
        return "{{\(variables[index].name).\(field.name)}}"
    }

    /// Changes a field, following a change of its name through the text.
    public mutating func updateFormField(named old: String, to field: FormField) {
        if isShortForm {
            var properties = formFields[old]?.map ?? []
            field.apply(to: &properties)
            if old != field.name {
                formFields[old] = nil
                body = pieces.map { $0.kind == .field(old) ? "[[\(field.name)]]" : $0.source }.joined()
            }
            formFields[field.name] = properties.isEmpty ? nil : .map(properties)
            return
        }
        guard let index = formVariableIndex, variables[index].layoutFieldNames.contains(old) else { return }
        var properties = variables[index].properties(ofField: old)
        field.apply(to: &properties)
        if old != field.name { variables[index].setProperties(nil, ofField: old) }
        variables[index].setProperties(properties, ofField: field.name)
        if old != field.name || variables[index].label(ofField: old) != field.label {
            variables[index].setLayout(ofField: old, label: field.label, name: field.name)
        }
        if old != field.name {
            let form = variables[index].name
            body = pieces.map { piece in
                piece.kind == .variable(name: form, field: old) ? "{{\(form).\(field.name)}}" : piece.source
            }.joined()
        }
    }

    /// Removes a field and every reference to it in the text. Without its last field, the match goes back
    /// to plain text.
    public mutating func removeFormField(named name: String) {
        let before = body
        if isShortForm {
            body = pieces.filter { $0.kind != .field(name) }.map(\.source).joined()
        } else if let index = formVariableIndex {
            let form = variables[index].name
            body = pieces.filter { $0.kind != .variable(name: form, field: name) }.map(\.source).joined()
            if body == before {
                // The field was only in the layout.
                dropField(name, fromFormAt: index)
                return
            }
        }
        reconcile(afterBodyChangedFrom: before)
    }

    private mutating func dropField(_ name: String, fromFormAt index: Int) {
        variables[index].removeFromLayout(field: name)
        variables[index].setProperties(nil, ofField: name)
        if variables[index].layoutFieldNames.isEmpty {
            variables.remove(at: index)
        }
    }

    /// Rewrites a match that uses the short `form:` key in the long form: a form variable whose layout
    /// lists the fields, and `{{form1.field}}` in the text.
    public mutating func convertToVerboseForm() {
        guard case .form(let text) = expansion else { return }
        let names = formFieldNames
        guard !names.isEmpty else {
            expansion = .text(text)
            formFields = []
            return
        }
        let formName = uniqueName("form")
        var form = SnippetVariable(name: formName, type: "form")
        form.layout = names.map { SnippetVariable.layoutLine(label: ExpansionPreview.humanized($0), name: $0) }
            .joined(separator: "\n")
        for name in names {
            if let properties = formFields[name]?.map { form.setProperties(properties, ofField: name) }
        }
        let converted = ExpansionPiece.pieces(of: text, isShortForm: true).map { piece -> String in
            if case .field(let name) = piece.kind { return "{{\(formName).\(name)}}" }
            return piece.source
        }.joined()
        expansion = .text(converted)
        formFields = []
        variables.append(form)
    }

    // MARK: Following the text

    /// Tidies up after the text changed: a variable or field whose last reference was removed from the text
    /// goes too, and a form without fields goes back to plain text.
    public mutating func reconcile(afterBodyChangedFrom old: String) {
        let before = Self.references(in: old, isShortForm: isShortForm)
        let after = Self.references(in: body, isShortForm: isShortForm)

        if isShortForm {
            for name in before.shortFields.subtracting(after.shortFields) {
                formFields[name] = nil
            }
            if after.shortFields.isEmpty, !before.shortFields.isEmpty {
                expansion = .text(body)
                formFields = []
            }
            return
        }

        for reference in before.fields.subtracting(after.fields) {
            guard let index = variables.firstIndex(where: { $0.name == reference.form && $0.type == "form" }) else { continue }
            dropField(reference.field, fromFormAt: index)
        }
        for name in before.variables.subtracting(after.variables) {
            guard let index = variables.firstIndex(where: { $0.name == name }), variables[index].type != "form" else { continue }
            if !isUsedByAnotherVariable(name) {
                variables.remove(at: index)
            }
        }
    }

    struct FieldReference: Hashable {
        var form: String
        var field: String
    }

    static func references(in text: String, isShortForm: Bool) -> (variables: Set<String>, fields: Set<FieldReference>, shortFields: Set<String>) {
        var variables = Set<String>(), fields = Set<FieldReference>(), shortFields = Set<String>()
        for piece in ExpansionPiece.pieces(of: text, isShortForm: isShortForm) {
            switch piece.kind {
            case .variable(let name, let field):
                if let field {
                    fields.insert(FieldReference(form: name, field: field))
                } else {
                    variables.insert(name)
                }
            case .field(let name):
                shortFields.insert(name)
            case .text, .cursor:
                break
            }
        }
        return (variables, fields, shortFields)
    }

    // MARK: Type

    /// Changes between Text, Markdown and HTML. The text stays exactly as it is; only the key it is written
    /// under changes. Nothing happens for a picture, which has no text to carry over.
    public mutating func setTextKind(_ kind: ExpansionKind) {
        guard kind != .picture, expansion.kind != .picture, expansion.kind != kind else { return }
        // The short form syntax exists only for plain text.
        if isShortForm { convertToVerboseForm() }
        switch kind {
        case .text: expansion = .text(body)
        case .markdown: expansion = .markdown(body)
        case .html: expansion = .html(body)
        case .picture: break
        }
    }
}

/// What a match's text referred to while it was being edited, so that undoing a deletion in the text box
/// brings back the variable or field that went with it.
public struct DynamicContentMemory: Sendable {
    private var variables: [String: SnippetVariable] = [:]
    private var fields: [MatchDraft.FieldReference: FormField] = [:]
    private var shortFields: [String: ParamValue] = [:]
    private var wasShortForm = false

    public init() {}

    /// Notes what the draft holds now.
    public mutating func record(_ draft: MatchDraft) {
        for variable in draft.variables {
            variables[variable.name] = variable
            guard variable.type == "form" else { continue }
            for name in variable.layoutFieldNames {
                fields[.init(form: variable.name, field: name)] = FormField(
                    name: name, label: variable.label(ofField: name), properties: variable.properties(ofField: name)
                )
            }
        }
        if draft.isShortForm {
            wasShortForm = true
            for entry in draft.formFields { shortFields[entry.key] = entry.value }
        }
    }

    /// Puts back whatever the draft's text refers to again.
    public func restore(into draft: inout MatchDraft) {
        if wasShortForm, case .text(let text) = draft.expansion, draft.formVariableIndex == nil,
           ExpansionPiece.pieces(of: text, isShortForm: true).contains(where: { if case .field = $0.kind { true } else { false } }) {
            draft.expansion = .form(text)
        }
        let references = MatchDraft.references(in: draft.body, isShortForm: draft.isShortForm)
        if draft.isShortForm {
            for name in references.shortFields where draft.formFields[name] == nil {
                if let properties = shortFields[name] { draft.formFields[name] = properties }
            }
            return
        }
        for name in references.variables where !draft.variables.contains(where: { $0.name == name }) {
            if let variable = variables[name], variable.type != "form" { draft.variables.append(variable) }
        }
        for reference in references.fields.sorted(by: { ($0.form, $0.field) < ($1.form, $1.field) }) {
            guard let field = fields[reference] else { continue }
            var index = draft.variables.firstIndex { $0.name == reference.form }
            if index == nil, variables[reference.form]?.type == "form" {
                draft.variables.append(SnippetVariable(name: reference.form, type: "form", params: [ParamEntry("layout", .string(""))]))
                index = draft.variables.count - 1
            }
            guard let index, draft.variables[index].type == "form",
                  !draft.variables[index].layoutFieldNames.contains(reference.field)
            else { continue }
            let line = SnippetVariable.layoutLine(label: field.label ?? ExpansionPreview.humanized(field.name), name: field.name)
            draft.variables[index].layout = draft.variables[index].layout.isEmpty ? line : draft.variables[index].layout + "\n" + line
            draft.variables[index].setProperties(field.properties, ofField: field.name)
        }
    }
}
