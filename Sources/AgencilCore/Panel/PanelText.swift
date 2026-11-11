import Foundation

/// A claim body as the ledger keeps it: a JSON object of `evidence`, `fix` and `confidence` (SittingStore.claim). The panel
/// shows the parts; a body that is not such an object is the claim text itself.
public struct ClaimBody: Sendable, Equatable {
    public let text: String
    public let fix: String?
    /// `95%`: the seat's own confidence, a hint and not a measurement.
    public let confidence: String?

    public init(text: String, fix: String?, confidence: Double?) {
        self.text = text
        self.fix = fix.flatMap { $0.isEmpty ? nil : $0 }
        self.confidence = Self.percent(confidence)
    }

    /// A confidence outside 0...1 is clamped and a non-number is dropped: the conversion to Int traps on either.
    public static func percent(_ confidence: Double?) -> String? {
        confidence.flatMap { $0.isFinite ? "\(Int((min(max($0, 0), 1) * 100).rounded()))%" : nil }
    }

    public init(_ body: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              object["evidence"] is String || object["fix"] is String || object["confidence"] is NSNumber else {
            self.init(text: body, fix: nil, confidence: nil)
            return
        }
        self.init(text: object["evidence"] as? String ?? "", fix: object["fix"] as? String,
                  confidence: (object["confidence"] as? NSNumber)?.doubleValue)
    }

    /// The evidence as code to show in a code block, or nil when it reads as prose. Seats are asked for a "quoted
    /// snippet" but some write a sentence, so the text decides: a fence, a markup tag, or mostly code-shaped lines.
    public static func code(_ evidence: String) -> String? {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") { return unfenced(trimmed) }
        // Markup leads the snippet, or tags outnumber a passing mention like "the <form> tag".
        let tags = trimmed.ranges(of: #/<\/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?\/?>/#).count
        if tags > 0 && (trimmed.hasPrefix("<") || tags >= 3) { return evidence.trimmingCharacters(in: .newlines) }
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.filter(codeShaped).count * 2 >= lines.count ? evidence.trimmingCharacters(in: .newlines) : nil
    }

    /// The lines between the opening fence and the closing one, indentation kept; an unclosed fence runs to the end.
    /// `\r\n` is one Character in Swift, so lines split on any newline.
    private static func unfenced(_ text: String) -> String {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).dropFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines = lines.dropLast() }
        return lines.joined(separator: "\n")
    }

    private static let codeEndings: Set<Character> = [";", "{", "}"]
    private static let codeTokens = ["=>", "::", "==", "!=", "&&", "||", "();", "->"]
    private static let codeStarts = ["func ", "let ", "const ", "var ", "def ", "fn ", "import ", "return ", "if (", "for (",
                                     "//", "#include", "SELECT ", "INSERT ", "UPDATE ", "CREATE "]

    /// A line ending in `;`, `{` or `}`, or opening like a statement, is code. A token such as `->` counts only on a line
    /// that does not read as a sentence: no final `.`, `?` or `!` and fewer than three plain words, so
    /// "Changing A -> B skips validation" and "A -> B skips auth." stay prose.
    private static func codeShaped(_ line: String) -> Bool {
        if line.last.map(codeEndings.contains) == true || codeStarts.contains(where: line.hasPrefix) { return true }
        if line.last.map({ ".?!".contains($0) }) == true { return false }
        let words = line.split(separator: " ").filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }.count
        return words < 3 && codeTokens.contains(where: line.contains)
    }
}

/// A model's answer for reading. Seats are told to answer with one JSON object; a person reads labelled lines instead.
/// Text that is not a JSON object or array is returned as it is.
public enum ReadableAnswer {
    public static func text(_ answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = unfenced(trimmed)
        guard body.first == "{" || body.first == "[",
              let value = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return answer }
        return lines(value, depth: 0).joined(separator: "\n")
    }

    static func unfenced(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)..<text.index(text.endIndex, offsetBy: -3)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func label(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func scalar(_ value: Any) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "yes" : "no" }
            let value = number.doubleValue
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
        case is NSNull: return "none"
        default: return nil
        }
    }

    private static func lines(_ value: Any, depth: Int) -> [String] {
        let pad = String(repeating: "  ", count: depth)
        if let object = value as? [String: Any] {
            return object.keys.sorted().flatMap { key -> [String] in
                guard let child = object[key] else { return [] }
                if let text = scalar(child) { return ["\(pad)\(label(key)): \(text)"] }
                return ["\(pad)\(label(key)):"] + lines(child, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, item -> [String] in
                if let text = scalar(item) { return ["\(pad)- \(text)"] }
                return ["\(pad)\(index + 1)."] + lines(item, depth: depth + 1)
            }
        }
        return []
    }
}
