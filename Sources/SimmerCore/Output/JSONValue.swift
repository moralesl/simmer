import Foundation

/// A tiny ordered JSON emitter. Hand-rolled on purpose: object key order is
/// stable (Codable's is not), which keeps `--json` output diffable across
/// runs — the property the differential idea in LEARNINGS.md leans on.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        lhs.serialized() == rhs.serialized()
    }

    public func serialized() -> String {
        switch self {
        case .string(let s): return "\"\(JSONValue.escape(s))\""
        case .int(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { "\"\(JSONValue.escape($0.0))\":\($0.1.serialized())" }
                .joined(separator: ",") + "}"
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
