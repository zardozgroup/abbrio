import Foundation

/// A value under a variable's `params:`, or under a form field: text, a number, a flag, a list or a mapping.
public indirect enum ParamValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    /// A bare value of another kind, such as `1.5` or `~`, kept as it is written.
    case other(String)
    case list([ParamValue])
    case map([ParamEntry])

    /// The value as text, for anything that isn't a list or a mapping.
    public var text: String? {
        switch self {
        case .string(let value), .other(let value): return value
        case .int(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .list, .map: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var list: [ParamValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    public var map: [ParamEntry]? {
        if case .map(let entries) = self { return entries }
        return nil
    }

    /// Every piece of text inside the value, lists and mappings included.
    public var allText: [String] {
        switch self {
        case .list(let items): return items.flatMap(\.allText)
        case .map(let entries): return entries.flatMap(\.value.allText)
        default: return text.map { [$0] } ?? []
        }
    }
}

/// One `key: value` line of a mapping. A mapping is a list of these, so the order in the file is kept.
public struct ParamEntry: Hashable, Sendable {
    public var key: String
    public var value: ParamValue

    public init(_ key: String, _ value: ParamValue) {
        self.key = key
        self.value = value
    }
}

extension Array where Element == ParamEntry {
    /// The value for a key. Setting a key that is there keeps its place; a new key goes to the end; nil
    /// removes the key.
    public subscript(key: String) -> ParamValue? {
        get { first { $0.key == key }?.value }
        set {
            if let position = firstIndex(where: { $0.key == key }) {
                if let newValue {
                    self[position].value = newValue
                } else {
                    remove(at: position)
                }
            } else if let newValue {
                append(ParamEntry(key, newValue))
            }
        }
    }
}
