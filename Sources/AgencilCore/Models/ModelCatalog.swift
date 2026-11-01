import Foundation

/// One model the owner can name in a seat: where it was found, who makes it, which harnesses run it, what it costs.
public struct ModelCatalogEntry: Identifiable, Equatable, Sendable {
    public enum Source: String, Comparable, Sendable {
        case harness, priceList, custom
        public static func < (left: Source, right: Source) -> Bool { left.order < right.order }
        private var order: Int { self == .custom ? 0 : self == .harness ? 1 : 2 }
    }

    public let id: String
    public let vendor: String
    public let harnesses: [String]
    public let sources: [Source]
    /// Nil when the price list does not price this model: shown as "no price", never estimated.
    public let price: ModelPrice?
    public let note: String
    /// Names of the seats that run this model.
    public let inUseBy: [String]
    public var isCustom: Bool { sources.contains(.custom) }
}

/// What the three sources know, merged by model id. Pure: no files, no processes.
public struct ModelCatalog: Equatable, Sendable {
    public struct Seat: Equatable, Sendable {
        public let name: String
        public let model: String
        public init(name: String, model: String) {
            self.name = name
            self.model = model
        }
    }

    /// The harness each provider's own models run on; every other provider's models are only priced.
    private static let nativeHarness = ["anthropic": "claude", "openai": "codex", "gemini": "gemini"]
    /// Short names the claude harness accepts.
    static let claudeAliases = ["opus", "sonnet", "haiku", "fable"]

    public let entries: [ModelCatalogEntry]

    public init(entries: [ModelCatalogEntry]) { self.entries = entries }

    public init(prices: [PriceListEntry], harnessLists: [String: [String]], custom: [CustomModel], seats: [Seat]) {
        struct Draft {
            var harnesses = Set<String>(), sources = Set<ModelCatalogEntry.Source>()
            var provider: String?, note = ""
        }
        var drafts: [String: Draft] = [:]
        let priced = Dictionary(prices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in prices {
            var draft = drafts[entry.id, default: Draft()]
            draft.sources.insert(.priceList)
            draft.provider = entry.provider
            if let harness = Self.nativeHarness[entry.provider] { draft.harnesses.insert(harness) }
            drafts[entry.id] = draft
        }
        for alias in Self.claudeAliases {
            drafts[alias, default: Draft()].harnesses.insert("claude")
            drafts[alias, default: Draft()].sources.insert(.harness)
        }
        for (harness, ids) in harnessLists {
            for id in ids {
                drafts[id, default: Draft()].harnesses.insert(harness)
                drafts[id, default: Draft()].sources.insert(.harness)
            }
        }
        for model in custom {
            drafts[model.id, default: Draft()].harnesses.insert(model.harness)
            drafts[model.id, default: Draft()].sources.insert(.custom)
            if !model.note.isEmpty { drafts[model.id, default: Draft()].note = model.note }
        }
        entries = drafts.map { id, draft in
            // A harness lists `provider/model`; the price list names the model without the provider.
            let listed = priced[id] ?? id.firstIndex(of: "/").flatMap { priced[String(id[id.index(after: $0)...])] }
            return ModelCatalogEntry(id: id, vendor: ModelVendor.of(model: id, provider: draft.provider ?? listed?.provider),
                                     harnesses: draft.harnesses.sorted(), sources: draft.sources.sorted(), price: listed?.price,
                                     note: draft.note, inUseBy: seats.filter { $0.model == id }.map(\.name).sorted())
        }.sorted { $0.id < $1.id }
    }

    /// Ids a seat of `harness` can name, for the seat sheet's picker. Any other id may still be typed.
    public func ids(for harness: String) -> [String] {
        entries.filter { $0.harnesses.contains(harness) }.map(\.id)
    }
}
