import Foundation

/// Text-level reading of the two config formats install-mcp edits. The files are the user's: Agencil inserts and
/// removes its own text at byte positions and never re-serializes, so everything else stays byte-identical.
enum ConfigText {
    struct Member { let key: String; let value: Range<Int> }

    // MARK: JSON (objects only, no comments)

    /// The members of the object whose `{` is at or after `start`, and the index of its closing `}`.
    static func members(of bytes: [UInt8], objectAt start: Int) -> (members: [Member], close: Int)? {
        var index = skipSpace(bytes, start)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        index = skipSpace(bytes, index + 1)
        var found: [Member] = []
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { return ([], index) }
        while index < bytes.count {
            guard let keyEnd = stringEnd(bytes, index),
                  let key = try? JSONSerialization.jsonObject(with: Data(bytes[index..<keyEnd]), options: .fragmentsAllowed) as? String
            else { return nil }
            index = skipSpace(bytes, keyEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index = skipSpace(bytes, index + 1)
            guard let valueEnd = valueEnd(bytes, index) else { return nil }
            found.append(Member(key: key, value: index..<valueEnd))
            index = skipSpace(bytes, valueEnd)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "}") { return (found, index) }
            guard bytes[index] == UInt8(ascii: ",") else { return nil }
            index = skipSpace(bytes, index + 1)
        }
        return nil
    }

    private static func skipSpace(_ bytes: [UInt8], _ from: Int) -> Int {
        var index = from
        while index < bytes.count, [32, 9, 10, 13].contains(bytes[index]) { index += 1 }
        return index
    }

    private static func stringEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "\"") else { return nil }
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
            if bytes[index] == UInt8(ascii: "\"") { return index + 1 }
            index += 1
        }
        return nil
    }

    private static func valueEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        if bytes[start] == UInt8(ascii: "\"") { return stringEnd(bytes, start) }
        guard bytes[start] == UInt8(ascii: "{") || bytes[start] == UInt8(ascii: "[") else {
            var index = start
            while index < bytes.count, ![44, 125, 93, 32, 9, 10, 13].contains(bytes[index]) { index += 1 }
            return index > start ? index : nil
        }
        var depth = 0, index = start
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""): guard let end = stringEnd(bytes, index) else { return nil }; index = end; continue
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return index + 1 }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// A quoted string valid in both JSON and TOML (JSONSerialization would escape "/", which TOML rejects).
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    // MARK: TOML (parsing lives in TomlCheck; this finds the lines that declare an agencil server)

    /// True when the document already declares `mcp_servers.agencil` in any of the usual spellings.
    static func tomlDeclaresAgencil(_ text: String) -> Bool {
        var inServers = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.drop { $0 == "[" }.prefix { $0 != "]" }.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: " ", with: "")
                if name == "mcp_servers.agencil" || name.hasPrefix("mcp_servers.agencil.") { return true }
                inServers = name == "mcp_servers"
                continue
            }
            let compact = line.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
            if compact.hasPrefix("mcp_servers.agencil") { return true }
            if compact.hasPrefix("mcp_servers=") && compact.contains("agencil") { return true }
            if inServers && compact.hasPrefix("agencil") && (compact.hasPrefix("agencil=") || compact.hasPrefix("agencil.")) { return true }
        }
        return false
    }
}
