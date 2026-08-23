import ArgumentParser
import Foundation
import SimmerCore

// The entry point. Sugar is normalised first (bare `simmer`, `simmer 2h`,
// `+20m`, `down`), then ArgumentParser handles the canonical grammar. Errors
// are mapped by hand because exit codes are API: every refusal and parse
// failure is 1, never ArgumentParser's 64.

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
    let message = SimmerRoot.fullMessage(for: error)
    if exitCode.isSuccess {
        if !message.isEmpty { print(message) }
        exit(0)
    }
    if !message.isEmpty {
        FileHandle.standardError.write(Data(("simmer: " + message + "\n").utf8))
    }
    exit(1)
}
