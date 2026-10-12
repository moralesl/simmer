import Foundation
import Testing
@testable import SimmerCore

/// The refusal object's mechanics: what `Outcome.failure` writes for each kind,
/// and the exit code each kind carries. Which refusal each command raises is
/// the acceptance suite's question (`RefusalKindTests`), asked of the binary.
@Suite struct RefusalTests {
    private func object(_ outcome: Outcome) -> [String: Any] {
        let line = outcome.stdout.first ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    @Test(arguments: Refusal.allCases)
    func theObjectNamesWhatRefused(_ refusal: Refusal) {
        let outcome = Outcome.failure("a sentence for a person", by: refusal, json: true)
        #expect(outcome.stdout.count == 1)
        #expect(outcome.stderr.isEmpty)
        let fields = object(outcome)
        #expect(fields["action"] as? String == "refused")
        #expect(fields["error"] as? String == "a sentence for a person")
        #expect(fields["refused_by"] as? String == refusal.rawValue)
        #expect(fields.count == 3, "\(fields.keys.sorted())")
    }

    /// Appended, never inserted: a reader that took the first two fields by
    /// position still finds them where they were.
    @Test func refusedByComesAfterTheFieldsThatWereThereFirst() {
        let line = Outcome.failure("x", by: .cap, json: true).stdout.first ?? ""
        #expect(line == #"{"action":"refused","error":"x","refused_by":"cap"}"#)
    }

    /// 2 is the call itself and nothing else. Every kind that is about the
    /// machine, the ceiling or the caller's standing is a 1.
    @Test(arguments: Refusal.allCases)
    func onlyUsageExitsTwo(_ refusal: Refusal) {
        let outcome = Outcome.failure("x", by: refusal)
        #expect(outcome.exit == (refusal == .usage ? 2 : 1))
        #expect(refusal.exitCode == outcome.exit)
    }

    /// `run` answers 127 when the command cannot be started at all — the
    /// shell's own code for it — and an explicit exit wins over the kind's.
    @Test func anExplicitExitWins() {
        #expect(Outcome.failure("could not run x", by: .system, exit: 127).exit == 127)
        #expect(Outcome.failure("x", by: .usage, exit: 1).exit == 1)
    }

    /// The person reads the sentence; the kind is for a parser and stays out
    /// of the prose, which may be reworded at any time.
    @Test func aPersonGetsTheSentenceOnStderrAndNothingElse() {
        let outcome = Outcome.failure("the cap has passed", by: .cap)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr == ["simmer: the cap has passed"])
    }

    /// The raw values are machine surface. Pinned here so a rename is a red
    /// test rather than a quiet contract change.
    @Test func theRawValuesAreTheContractedSpellings() {
        #expect(Refusal.allCases.map(\.rawValue) == [
            "usage", "cap", "floor", "charger", "authority", "no_claim", "no_deadline", "system",
        ])
    }
}
