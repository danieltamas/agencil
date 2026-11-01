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
        // A confidence outside 0...1 is clamped and a non-number is dropped: the conversion to Int traps on either.
        self.confidence = confidence.flatMap { $0.isFinite ? "\(Int((min(max($0, 0), 1) * 100).rounded()))%" : nil }
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
