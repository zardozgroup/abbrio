import Foundation

/// Finds triggers that more than one active match uses.
///
/// Espanso shows a choice dialog when triggers collide, so the app flags them. Only sets that are on are
/// compared, because a set that is off is not loaded. Triggers are compared exactly, as Espanso does.
public struct DuplicateIndex: Sendable {
    public struct Conflict: Hashable, Sendable {
        public var trigger: String
        /// Names of the other sets that use the trigger. Empty when the clash is inside the same set.
        public var otherSetNames: [String]
    }

    private var conflictsBySnippet: [Snippet.ID: [Conflict]] = [:]

    public init(sets: [SnippetSet]) {
        struct Use {
            var snippet: Snippet.ID
            var setID: String
            var setName: String
        }

        var uses: [String: [Use]] = [:]
        for set in sets where set.isEnabled {
            for snippet in set.snippets where !snippet.isRegex {
                for trigger in Set(snippet.triggers) {
                    uses[trigger, default: []].append(Use(snippet: snippet.id, setID: set.id, setName: set.name))
                }
            }
        }

        for (trigger, list) in uses where list.count > 1 {
            for use in list {
                var names: [String] = []
                for other in list where other.setID != use.setID && !names.contains(other.setName) {
                    names.append(other.setName)
                }
                conflictsBySnippet[use.snippet, default: []].append(
                    Conflict(trigger: trigger, otherSetNames: names.sorted())
                )
            }
        }
        for key in conflictsBySnippet.keys {
            conflictsBySnippet[key]?.sort { $0.trigger < $1.trigger }
        }
    }

    public func conflicts(for snippet: Snippet.ID) -> [Conflict] {
        conflictsBySnippet[snippet] ?? []
    }

    public func hasConflicts(in set: SnippetSet) -> Bool {
        set.snippets.contains { conflictsBySnippet[$0.id] != nil }
    }

    /// Every conflict that involves a match of the set, one entry per trigger.
    public func conflicts(in set: SnippetSet) -> [Conflict] {
        var seen = Set<String>()
        var result: [Conflict] = []
        for snippet in set.snippets {
            for conflict in conflicts(for: snippet.id) where seen.insert(conflict.trigger).inserted {
                result.append(conflict)
            }
        }
        return result
    }
}
