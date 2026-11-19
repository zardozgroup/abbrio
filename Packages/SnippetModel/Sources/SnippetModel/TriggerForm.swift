import Foundation

/// The triggers of a match the way the form shows them: without the set's prefix and suffix, and with the
/// case variants of "Case does not matter" folded into one abbreviation.
public struct TriggerForm: Hashable, Sendable {
    /// The abbreviation without the set's prefix and suffix.
    public var abbreviation: String
    /// Further abbreviations, also without prefix and suffix.
    public var aliases: [String]
    /// True when each abbreviation is written with its lowercase, Capitalized and UPPERCASE forms.
    public var isCaseInsensitive: Bool
    /// False when the triggers in the file don't all carry the set's prefix and suffix. They are then shown
    /// and written as they are.
    public var usesAffixes: Bool

    public init(abbreviation: String = "", aliases: [String] = [], isCaseInsensitive: Bool = false, usesAffixes: Bool = true) {
        self.abbreviation = abbreviation
        self.aliases = aliases
        self.isCaseInsensitive = isCaseInsensitive
        self.usesAffixes = usesAffixes
    }

    /// Reads the triggers of a match.
    ///
    /// - Parameters:
    ///   - triggers: The triggers as written in the file.
    ///   - caseInsensitive: What the app noted about the match. It is believed only when the triggers really
    ///     are the case variants of fewer abbreviations.
    public init(triggers: [String], prefix: String, suffix: String, caseInsensitive: Bool) {
        let hasAffix = !prefix.isEmpty || !suffix.isEmpty
        let conforms = triggers.allSatisfy { Self.carries($0, prefix: prefix, suffix: suffix) }
        usesAffixes = !hasAffix || conforms || triggers.allSatisfy(\.isEmpty)
        let bare = usesAffixes && hasAffix
            ? triggers.map { Self.strip($0, prefix: prefix, suffix: suffix) }
            : triggers

        var folded: [String] = []
        if caseInsensitive {
            for trigger in bare where !folded.contains(where: { Self.variants(of: $0).contains(trigger) }) {
                folded.append(trigger)
            }
        }
        if caseInsensitive, folded.flatMap({ Self.variants(of: $0) }) == bare {
            isCaseInsensitive = true
            abbreviation = folded.first ?? ""
            aliases = Array(folded.dropFirst())
        } else {
            isCaseInsensitive = false
            abbreviation = bare.first ?? ""
            aliases = Array(bare.dropFirst())
        }
    }

    /// The triggers to write to the file.
    public func triggers(prefix: String, suffix: String) -> [String] {
        var result: [String] = []
        for bare in [abbreviation] + aliases {
            // An empty abbreviation stays empty, so that it is refused instead of saved as a bare prefix.
            guard !bare.isEmpty else {
                result.append("")
                continue
            }
            let forms = isCaseInsensitive ? Self.variants(of: bare) : [bare]
            for form in forms {
                let trigger = usesAffixes ? prefix + form + suffix : form
                if !result.contains(trigger) { result.append(trigger) }
            }
        }
        return result
    }

    /// The forms written for "Case does not matter": as typed, lowercase, Capitalized and UPPERCASE, without
    /// repeats. `btw` gives `btw`, `Btw`, `BTW`.
    public static func variants(of abbreviation: String) -> [String] {
        let lower = abbreviation.lowercased()
        var capitalized = ""
        var seenLetter = false
        for character in lower {
            if !seenLetter, character.isLetter {
                capitalized += character.uppercased()
                seenLetter = true
            } else {
                capitalized.append(character)
            }
        }
        var result: [String] = []
        for form in [abbreviation, lower, capitalized, abbreviation.uppercased()] where !result.contains(form) {
            result.append(form)
        }
        return result
    }

    /// True when the trigger starts with the prefix, ends with the suffix and has something in between.
    public static func carries(_ trigger: String, prefix: String, suffix: String) -> Bool {
        trigger.count > prefix.count + suffix.count && trigger.hasPrefix(prefix) && trigger.hasSuffix(suffix)
    }

    public static func strip(_ trigger: String, prefix: String, suffix: String) -> String {
        guard carries(trigger, prefix: prefix, suffix: suffix) else { return trigger }
        return String(trigger.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// A trigger after the set's prefix and suffix changed. A trigger that lacks the old ones gets the new
    /// ones added to what it is.
    public static func reaffix(
        _ trigger: String, from old: (prefix: String, suffix: String), to new: (prefix: String, suffix: String)
    ) -> String {
        new.prefix + strip(trigger, prefix: old.prefix, suffix: old.suffix) + new.suffix
    }
}
