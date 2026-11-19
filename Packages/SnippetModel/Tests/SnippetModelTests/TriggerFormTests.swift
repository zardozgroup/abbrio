import XCTest
import SnippetModel

final class TriggerFormTests: XCTestCase {
    func testVariants() {
        XCTAssertEqual(TriggerForm.variants(of: "btw"), ["btw", "Btw", "BTW"])
        XCTAssertEqual(TriggerForm.variants(of: ";btw"), [";btw", ";Btw", ";BTW"])
        XCTAssertEqual(TriggerForm.variants(of: "BTW"), ["BTW", "btw", "Btw"])
        XCTAssertEqual(TriggerForm.variants(of: "bTw"), ["bTw", "btw", "Btw", "BTW"])
        XCTAssertEqual(TriggerForm.variants(of: ";1"), [";1"])
        XCTAssertEqual(TriggerForm.variants(of: "éa"), ["éa", "Éa", "ÉA"])
    }

    func testCompileAddsAffixesAndVariants() {
        let plain = TriggerForm(abbreviation: "addr", aliases: ["home"])
        XCTAssertEqual(plain.triggers(prefix: ",", suffix: ""), [",addr", ",home"])
        XCTAssertEqual(plain.triggers(prefix: "", suffix: "/"), ["addr/", "home/"])

        let folded = TriggerForm(abbreviation: "btw", aliases: ["fyi"], isCaseInsensitive: true)
        XCTAssertEqual(folded.triggers(prefix: ";", suffix: ""), [";btw", ";Btw", ";BTW", ";fyi", ";Fyi", ";FYI"])
        // An empty abbreviation stays empty, so it is refused instead of saved as a bare prefix.
        XCTAssertEqual(TriggerForm().triggers(prefix: ";", suffix: ""), [""])
    }

    func testReadingBackIsTheInverse() {
        for form in [
            TriggerForm(abbreviation: "addr", aliases: ["home"]),
            TriggerForm(abbreviation: "btw", aliases: ["fyi"], isCaseInsensitive: true),
            TriggerForm(abbreviation: "BTW", isCaseInsensitive: true),
            TriggerForm(abbreviation: "7", isCaseInsensitive: true),
        ] {
            for (prefix, suffix) in [("", ""), (";", ""), ("x", "/")] {
                let triggers = form.triggers(prefix: prefix, suffix: suffix)
                XCTAssertEqual(
                    TriggerForm(triggers: triggers, prefix: prefix, suffix: suffix, caseInsensitive: form.isCaseInsensitive),
                    form, "\(triggers)"
                )
            }
        }
    }

    func testAStaleNoteIsIgnored() {
        // The note says "case does not matter", but the triggers are not the variants of fewer abbreviations.
        let form = TriggerForm(triggers: ["btw", "Btw"], prefix: "", suffix: "", caseInsensitive: true)
        XCTAssertFalse(form.isCaseInsensitive)
        XCTAssertEqual(form.aliases, ["Btw"])
    }

    func testTriggersWithoutTheSetsPrefixAreLeftAsWritten() {
        let form = TriggerForm(triggers: [";a", "b"], prefix: ";", suffix: "", caseInsensitive: false)
        XCTAssertFalse(form.usesAffixes)
        XCTAssertEqual(form.abbreviation, ";a")
        XCTAssertEqual(form.triggers(prefix: ";", suffix: ""), [";a", "b"])
        // A trigger that is nothing but the prefix does not carry it.
        XCTAssertFalse(TriggerForm.carries(";", prefix: ";", suffix: ""))
    }

    func testReaffix() {
        XCTAssertEqual(TriggerForm.reaffix(";addr", from: (";", ""), to: (",", "")), ",addr")
        XCTAssertEqual(TriggerForm.reaffix("addr", from: ("", ""), to: (":", ":")), ":addr:")
        XCTAssertEqual(TriggerForm.reaffix(":addr:", from: (":", ":"), to: ("", "")), "addr")
        XCTAssertEqual(TriggerForm.reaffix("odd", from: (";", ""), to: (",", "")), ",odd")
    }

    func testSetInfoToleratesMissingFields() throws {
        let info = try JSONDecoder().decode(SetInfo.self, from: Data(#"{"prefix":";","defaultCase":"unknown"}"#.utf8))
        XCTAssertEqual(info, SetInfo(prefix: ";"))
        XCTAssertTrue(SetInfo().isEmpty)
    }
}
