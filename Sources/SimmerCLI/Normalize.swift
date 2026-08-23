import Foundation

/// Canonical verbs, with the everyday spellings kept as documented sugar
/// (DESIGN-NOTES, adopted): `simmer 2h` is `claim 2h`, `+20m` is `extend 20m`,
/// `down` is `release`. Normalising up front keeps the parser regular — every
/// new verb would otherwise risk colliding with something that looks like a
/// duration.
enum Normalize {
    static let verbs: Set<String> = [
        "claim", "extend", "release", "cap", "status", "budget", "run",
        "guard", "doctor", "log", "render", "notify-test", "notify-post",
    ]

    static func arguments(_ args: [String]) -> [String] {
        guard let first = args.first else { return ["status"] }
        let rest = Array(args.dropFirst())
        switch first {
        case "--machine", "--porcelain":
            return ["status", "--machine"] + rest
        case "--json":
            return ["status", "--json"] + rest
        case "down", "off", "stop":
            return ["release"] + rest
        case "forever", "--forever", "--indefinite":
            return ["claim", "forever"] + rest
        case let plus where plus.hasPrefix("+"):
            return ["extend", plus] + rest
        case let verb where verbs.contains(verb):
            return args
        default:
            // A duration, a claim flag, or a typo — claim owns the diagnosis
            // ("did not understand the duration: …").
            return ["claim"] + args
        }
    }
}
