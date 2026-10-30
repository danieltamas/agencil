import Foundation

/// A strict TOML 1.0 reader that only answers "does this document parse": tables, dotted keys, every value
/// kind, duplicate keys and tables. install-mcp edits a config only after this says yes, and refuses (never repairs) otherwise.
struct TomlCheck {
    private let c: [Character]
    private var i = 0

    static func parses(_ text: String) -> Bool {
        var check = TomlCheck(c: Array(text))
        return check.document()
    }

    private init(c: [Character]) { self.c = c }

    private mutating func document() -> Bool {
        var table = ""
        var seen: Set<String> = []
        while true {
            skipBlank()
            guard i < c.count else { return true }
            if c[i] == "[" {
                let array = i + 1 < c.count && c[i + 1] == "["
                i += array ? 2 : 1
                skipSpace()
                guard let name = keyPath() else { return false }
                skipSpace()
                guard take("]"), !array || take("]") else { return false }
                table = name
                guard seen.insert("[\(name)]").inserted || array else { return false }
            } else {
                guard let key = keyPath() else { return false }
                skipSpace()
                guard take("=") else { return false }
                skipSpace()
                guard seen.insert("\(table)\u{0}\(key)").inserted, value() else { return false }
            }
            guard endOfLine() else { return false }
        }
    }

    private mutating func value() -> Bool {
        guard i < c.count else { return false }
        switch c[i] {
        case "\"": return string(quote: "\"", escapes: true)
        case "'": return string(quote: "'", escapes: false)
        case "[": return array()
        case "{": return inlineTable()
        default: return scalar()
        }
    }

    private mutating func string(quote: Character, escapes: Bool) -> Bool {
        let triple = i + 2 < c.count && c[i + 1] == quote && c[i + 2] == quote
        i += triple ? 3 : 1
        while i < c.count {
            let character = c[i]
            if escapes && character == "\\" { i += 2; continue }
            if character == quote {
                if !triple { i += 1; return true }
                if i + 2 < c.count + 0, c[i + 1] == quote, c[i + 2] == quote {
                    i += 3
                    while i < c.count, c[i] == quote { i += 1 }
                    return true
                }
            }
            if !triple && (character == "\n" || character == "\r") { return false }
            i += 1
        }
        return false
    }

    private mutating func array() -> Bool {
        i += 1
        while true {
            skipBlank()
            if take("]") { return true }
            guard value() else { return false }
            skipBlank()
            if take("]") { return true }
            guard take(",") else { return false }
        }
    }

    private mutating func inlineTable() -> Bool {
        i += 1
        var keys: Set<String> = []
        skipSpace()
        if take("}") { return true }
        while true {
            skipSpace()
            guard let key = keyPath(), keys.insert(key).inserted else { return false }
            skipSpace()
            guard take("=") else { return false }
            skipSpace()
            guard value() else { return false }
            skipSpace()
            if take("}") { return true }
            guard take(",") else { return false }
        }
    }

    private static let scalars: [NSRegularExpression] = [
        #"^(true|false|[+-]?(inf|nan))$"#,
        #"^[+-]?(0|[1-9](_?[0-9])+|[1-9])$"#,
        #"^0x[0-9A-Fa-f](_?[0-9A-Fa-f])*$"#, #"^0o[0-7](_?[0-7])*$"#, #"^0b[01](_?[01])*$"#,
        #"^[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?$"#,
        #"^[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?)?$"#,
        #"^[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private mutating func scalar() -> Bool {
        var token = ""
        while i < c.count, !",]}#\n\r".contains(c[i]), c[i] != "\t" {
            // A date and its time may be separated by one space.
            if c[i] == " " {
                guard token.count == 10, i + 1 < c.count, c[i + 1].isNumber else { break }
            }
            token.append(c[i])
            i += 1
        }
        let range = NSRange(token.startIndex..., in: token)
        return !token.isEmpty && Self.scalars.contains { $0.firstMatch(in: token, range: range) != nil }
    }

    private mutating func keyPath() -> String? {
        var parts: [String] = []
        while true {
            guard i < c.count else { return nil }
            if c[i] == "\"" || c[i] == "'" {
                let quote = c[i]
                let start = i + 1
                guard string(quote: quote, escapes: quote == "\"") else { return nil }
                parts.append(String(c[start..<(i - 1)]))
            } else {
                let start = i
                while i < c.count, c[i].isASCII, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "-" { i += 1 }
                guard i > start else { return nil }
                parts.append(String(c[start..<i]))
            }
            skipSpace()
            guard take(".") else { return parts.joined(separator: ".") }
            skipSpace()
        }
    }

    private mutating func take(_ character: Character) -> Bool {
        guard i < c.count, c[i] == character else { return false }
        i += 1
        return true
    }

    private mutating func skipSpace() { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }

    /// Whitespace, newlines and comments between statements and inside arrays.
    private mutating func skipBlank() {
        while i < c.count {
            if " \t\n\r".contains(c[i]) { i += 1 } else if c[i] == "#" { while i < c.count, c[i] != "\n" { i += 1 } } else { return }
        }
    }

    private mutating func endOfLine() -> Bool {
        skipSpace()
        if i < c.count, c[i] == "#" { while i < c.count, c[i] != "\n" { i += 1 } }
        if i >= c.count { return true }
        if c[i] == "\r" { i += 1 }
        return take("\n")
    }
}
