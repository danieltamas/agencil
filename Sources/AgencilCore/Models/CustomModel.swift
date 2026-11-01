import Foundation

/// A model the owner added by hand: one `custom_models` entry of config.json (JSON text, like the other lists).
public struct CustomModel: Equatable, Codable, Sendable {
    public var id: String
    public var harness: String
    public var note: String

    public init(id: String, harness: String, note: String = "") {
        self.id = id
        self.harness = harness
        self.note = note
    }

    static let idPattern = #"\A[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,119}\z"#
    static let noteLimit = 120

    /// One message per field name; empty when the model is acceptable.
    func problems() -> [String: String] {
        var found: [String: String] = [:]
        if id.range(of: Self.idPattern, options: .regularExpression) == nil {
            found["id"] = "1 to 120 characters: letters, digits and . _ : / @ + -"
        }
        if !SeatConfig.harnesses.contains(harness) { found["harness"] = "pick one of the known harnesses" }
        if note.count > Self.noteLimit || note.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            found["note"] = "at most \(Self.noteLimit) characters on one line"
        }
        return found
    }

    /// The list as config.json holds it. A text that is not a valid list is an error, never an empty list.
    public static func parse(_ text: String?) throws -> [CustomModel] {
        try SeatConfig.array(text, "custom_models").map { item in
            guard let id = item["id"] as? String, let harness = item["harness"] as? String else {
                throw ConfigProblem(key: "custom_models", problem: "every entry needs an id and a harness")
            }
            let model = CustomModel(id: id, harness: harness, note: item["note"] as? String ?? "")
            if let problem = model.problems().values.first { throw ConfigProblem(key: "custom_models", problem: "\(id): \(problem)") }
            return model
        }
    }

    var object: [String: Any] {
        var object: [String: Any] = ["id": id, "harness": harness]
        if !note.isEmpty { object["note"] = note }
        return object
    }
}
