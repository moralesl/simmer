import ArgumentParser
import Foundation
import SimmerCore

// The entry point. Sugar is normalised first (bare `simmer`, `simmer 2h`,
// `+20m`, `down`), then ArgumentParser handles the canonical grammar. Errors
// are mapped by hand because exit codes are API: a parse failure is 2 and a
// refusal 1, never ArgumentParser's 64.

let rawArguments = Array(CommandLine.arguments.dropFirst())

switch rawArguments.first {
case "-V", "--version", "version":
    print("simmer \(Runtime.version)")
    exit(0)
case "-h", "--help", "help":
    print(Help.text)
    exit(0)
default:
    break
}

let normalized = Normalize.arguments(rawArguments)

do {
    var command = try SimmerRoot.parseAsRoot(normalized)
    try command.run()
} catch let exitCode as ExitCode {
    exit(exitCode.rawValue)
} catch {
    let exitCode = SimmerRoot.exitCode(for: error)
    if exitCode.isSuccess {
        let message = SimmerRoot.fullMessage(for: error)
        if !message.isEmpty { print(message) }
        exit(0)
    }
    // A `--json` caller gets the refusal object, even when the refusal came
    // from the parser rather than from a command. The alternative is what this
    // replaced: an empty stdout stream, which is indistinguishable to the
    // caller from a command that worked and had nothing to say — the exact
    // failure the "honoured or refused, never accepted and dropped" rule
    // exists to prevent (AGENTS.md, CONTRACTS.md § Surface guarantees).
    //
    // Deliberately the one-line `message(for:)` and not `fullMessage(for:)`:
    // the latter appends usage text naming internal subcommand spellings
    // nobody typed, which belongs in a human's terminal and not in a
    // contracted field.
    //
    // Everything that reaches here came from the parser: the commands throw
    // nothing but `ExitCode`, caught above. So it is a usage error, and exit 2
    // keeps a typo apart from `budget`'s 1 ("not enough time — wind down"),
    // which is what the same typo used to answer.
    if rawArguments.contains("--json") {
        Runtime.deliver(.failure(SimmerRoot.message(for: error), by: .usage, json: true))
    }
    let message = SimmerRoot.fullMessage(for: error)
    if !message.isEmpty {
        FileHandle.standardError.write(Data(("simmer: " + message + "\n").utf8))
    }
    exit(Refusal.usage.exitCode)
}
