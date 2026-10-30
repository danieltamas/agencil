import Foundation

/// Argument checking against the advertised input schemas, and the size caps on what a result may carry
/// (docs/AGENT-API.md, "MCP server"). Both fail closed: an argument off-schema is a protocol fault, and a
/// value over its cap is cut at a UTF-8 boundary with `<field>_truncated: true` beside it.
enum MCPBounds {
    private static let caps: [String: Int] = ["answer": 256 * 1024, "evidence": 4096, "reason": 1024, "why": 1024, "question": 65_536]
    private static let resultLimit = 1_048_576

    /// The first way `arguments` departs from `schema` (required, types, lengths, no extra keys), or nil.
    static func violation(_ arguments: [String: Any], schema: [String: Any]) -> String? {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] where arguments[key] == nil { return "\(key) is required" }
        for (key, value) in arguments {
            guard let rule = properties[key] else { return "\(key) is not an argument of this tool" }
            if let problem = check(value, rule, name: key) { return problem }
        }
        return nil
    }

    private static func check(_ value: Any, _ rule: [String: Any], name: String) -> String? {
        let number = value as? NSNumber
        let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch rule["type"] as? String {
        case "string":
            guard let text = value as? String else { return "\(name) must be a string" }
            if let limit = rule["maxLength"] as? Int, text.count > limit { return "\(name) is longer than \(limit)" }
        case "integer":
            guard let number, !isBool, number.doubleValue == number.doubleValue.rounded() else { return "\(name) must be an integer" }
            if let low = rule["minimum"] as? Int, number.intValue < low { return "\(name) is below \(low)" }
            if let high = rule["maximum"] as? Int, number.intValue > high { return "\(name) is above \(high)" }
        case "boolean":
            guard isBool else { return "\(name) must be a boolean" }
        case "array":
            guard let items = value as? [Any] else { return "\(name) must be an array" }
            let element = rule["items"] as? [String: Any] ?? [:]
            for item in items { if let problem = check(item, element, name: name) { return problem } }
        default: break
        }
        return nil
    }

    /// Caps the named fields anywhere in `data`, then drops list tails until the whole result fits.
    static func bounded(_ data: [String: Any]) -> [String: Any] {
        var result = capFields(data)
        while serializedSize(result) > resultLimit, let trimmed = dropLastListItem(result) {
            result = trimmed
            result["truncated"] = true
        }
        return result
    }

    private static func capFields(_ object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in object {
            if let text = value as? String, let cap = caps[key], text.utf8.count > cap {
                out[key] = cut(text, bytes: cap)
                out[key + "_truncated"] = true
            } else if let nested = value as? [String: Any] { out[key] = capFields(nested) }
            else if let list = value as? [[String: Any]] { out[key] = list.map(capFields) }
            else { out[key] = value }
        }
        return out
    }

    private static func cut(_ text: String, bytes: Int) -> String {
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: bytes)
        while end > text.utf8.startIndex, String(text.utf8[..<end]) == nil { end = text.utf8.index(before: end) }
        return String(text.utf8[..<end]) ?? ""
    }

    private static func serializedSize(_ object: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: object).count) ?? 0
    }

    private static func dropLastListItem(_ object: [String: Any]) -> [String: Any]? {
        guard let (key, list) = object.compactMap({ pair -> (String, [Any])? in
            guard let list = pair.value as? [Any], !list.isEmpty else { return nil }
            return (pair.key, list)
        }).max(by: { $0.1.count < $1.1.count }) else { return nil }
        var copy = object
        copy[key] = Array(list.dropLast())
        return copy
    }
}
