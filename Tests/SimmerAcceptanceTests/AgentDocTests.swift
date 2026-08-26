import Foundation
import Testing

/// `AGENTS.md` shows agents a worked session and calls it real output. Nothing
/// checked that, and it is the fastest-rotting claim in the repository: machine
/// fields are append-only and a rename lands in `CONTRACTS.md` with a test, so
/// the suites stay green while the page an agent reads keeps the old name.
///
/// So the session is a fixture. Its commands are parsed out of the page rather
/// than restated here — a test that restated them would pass while the page said
/// something else, which is the whole failure being prevented.
///
/// Asserted: the exit code of every block, and that every field name shown still
/// appears in the real response. Values are not compared; the page elides most
/// of them with `...` anyway, and the names plus the exit codes are the contract.
@Suite struct AgentDocTests {
    static let page: String = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("AGENTS.md"),
                            encoding: .utf8)) ?? ""
    }()

    /// One `$ simmer …` invocation, the response shown under it, and the
    /// `# exit N` marker that closes it. Invocations without a marker are prose
    /// examples (the `command -v` guard, `simmer run`) and are not blocks.
    static let exitMarker = "# exit "

    static func blocks() -> [(args: [String], shown: String, exit: Int32, line: Int)] {
        var found: [(args: [String], shown: String, exit: Int32, line: Int)] = []
        var open: (args: [String], shown: String, line: Int)?

        for (index, raw) in page.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("$ simmer") {
                open = (tokenize(String(line.dropFirst("$ simmer".count))), "", index + 1)
            } else if var current = open {
                if line.hasPrefix(Self.exitMarker),
                   let code = Int32(line.dropFirst(Self.exitMarker.count).prefix(while: \.isNumber)) {
                    found.append((current.args, current.shown, code, current.line))
                    open = nil
                } else if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("#") {
                    open = nil
                } else {
                    current.shown += line   // the page wraps long JSON; rejoin it
                    open = current
                }
            }
        }
        return found
    }

    /// argv from a documented command line, honouring the quotes around reasons.
    static func tokenize(_ command: String) -> [String] {
        var args: [String] = [], current = "", quoted = false
        for character in command {
            if character == "\"" { quoted.toggle() }
            else if character == " " && !quoted {
                if !current.isEmpty { args.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    /// Replayed in order against one state directory — the only way it can be
    /// checked, since step 3's answer exists because of step 2.
    @Test func theDocumentedSessionIsRealOutput() {
        let session = Self.blocks()
        // A parser that matches nothing passes every assertion below.
        #expect(session.count >= 5, "parsed \(session.count) blocks — the parse broke")

        let sim = Sim()
        defer { sim.tearDown() }
        var namesChecked = 0

        for block in session {
            let result = sim.run(block.args)
            #expect(result.code == block.exit, """
                AGENTS.md:\(block.line) documents `simmer \(block.args.joined(separator: " "))` \
                exiting \(block.exit), got \(result.code) — \(result.out)\(result.err)
                """)
            for name in Self.fieldNames(in: block.shown) {
                namesChecked += 1
                #expect(result.out.contains("\"\(name)\":"),
                        "AGENTS.md:\(block.line) shows \"\(name)\", absent from: \(result.out)")
            }
        }
        #expect(namesChecked >= 20, "only \(namesChecked) field names checked — scan too narrow")
    }

    /// Every `"key":` in a shown response. The page's `...` elision matches
    /// nothing, which is what makes a truncated response safe to assert against.
    static func fieldNames(in shown: String) -> [String] {
        guard shown.hasPrefix("{") else { return [] }
        let pattern = try! NSRegularExpression(pattern: #""([a-z_]+)":"#)
        return pattern.matches(in: shown, range: NSRange(shown.startIndex..., in: shown))
            .compactMap { Range($0.range(at: 1), in: shown).map { String(shown[$0]) } }
    }
}
