import Foundation

/// The owner's own models (`custom_models`): same re-read, whole-config validation and single write as the other lists.
extension ConfigEditor {
    /// The list as the file holds it now. A file or list that cannot be read throws.
    public func customModels() throws -> [CustomModel] {
        do { return try CustomModel.parse(try read().values["custom_models"]) } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
    }

    @discardableResult
    public func add(customModel model: CustomModel) throws -> ConfigSnapshot {
        try changeCustomModels { list in
            try Self.check(model, among: list)
            return list + [model]
        }
    }

    @discardableResult
    public func update(customModel old: CustomModel, with model: CustomModel) throws -> ConfigSnapshot {
        try changeCustomModels { list in
            guard let at = list.firstIndex(of: old) else { throw SheetProblems.form("that model was removed meanwhile") }
            var others = list
            others.remove(at: at)
            try Self.check(model, among: others)
            var next = list
            next[at] = model
            return next
        }
    }

    @discardableResult
    public func remove(customModel model: CustomModel) throws -> ConfigSnapshot {
        try changeCustomModels { list in
            guard list.contains(model) else { throw SheetProblems.form("that model was removed meanwhile") }
            return list.filter { $0 != model }
        }
    }

    private static func check(_ model: CustomModel, among list: [CustomModel]) throws {
        var problems = model.problems()
        if problems.isEmpty, list.contains(where: { $0.id == model.id && $0.harness == model.harness }) {
            problems["id"] = "this model is already listed for \(model.harness)"
        }
        if !problems.isEmpty { throw SheetProblems(fields: problems) }
    }

    private func changeCustomModels(_ transform: ([CustomModel]) throws -> [CustomModel]) throws -> ConfigSnapshot {
        let snapshot = try read()
        let current: [CustomModel]
        do { current = try CustomModel.parse(snapshot.values["custom_models"]) } catch let problem as ConfigProblem {
            throw SheetProblems.form(problem.message)
        }
        let text = Self.json(try transform(current).map(\.object))
        do { _ = try SeatConfig(values: snapshot.values) } catch let problem as ConfigProblem { throw SheetProblems.form(problem.message) }
        return try write(snapshot, key: "custom_models", text: text)
    }
}
