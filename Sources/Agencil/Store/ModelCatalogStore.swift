import AgencilCore
import Foundation
import Observation

/// Settings > Models: the catalog (harness listings, the price list, the owner's own models), its filters, its
/// refresh and the Add model sheet. Files are read here; the merge itself is `ModelCatalog` in AgencilCore.
@MainActor @Observable final class ModelCatalogStore {
    enum Sheet: String, Identifiable { case model; var id: String { rawValue } }

    struct Form { var id = "", harness = "opencode", note = "" }

    static let columns = ["Input", "Cache read", "Cache write", "Output"]
    static let blank = PriceTable.blank

    private(set) var catalog = ModelCatalog(entries: [])
    private(set) var updatedAt: Date?
    private(set) var problem: String?
    private(set) var notes: [String] = []
    var filter = ""
    /// A harness name, or nil for every model.
    var harnessFilter: String?
    var presenting: Sheet?
    var form = Form()
    var problems: [String: String] = [:]
    var confirmingDelete = false

    /// The custom model the sheet edits; nil while it adds one.
    @ObservationIgnored var editing: CustomModel?
    @ObservationIgnored let editor: ConfigEditor?
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var endpoints: [String] = []
    @ObservationIgnored private var triedThisSession = false

    /// An inert store: no home, nothing read or written. `demo()` and the tests use it.
    init() {
        directory = nil
        editor = nil
        environment = [:]
    }

    init(directory: URL, environment: [String: String]) {
        self.directory = directory
        editor = ConfigEditor(directory: directory)
        self.environment = environment
        reload()
    }

    static func demo() -> ModelCatalogStore {
        let store = ModelCatalogStore()
        store.catalog = DemoCatalog.catalog
        store.updatedAt = DemoStore.now.addingTimeInterval(-DemoCatalog.age)
        return store
    }

    var source: String { ModelPriceList.source }
    var harnesses: [String] { SeatConfig.harnesses.sorted() }

    // MARK: reading

    /// Rebuilds the catalog from the cache and the config. A config or cache that cannot be read is a problem on the
    /// pane and leaves the last catalog in place; it is never shown as an empty one.
    func reload() {
        guard let directory else { return }
        do {
            let values = try ConfigStore(directory: directory).read().values
            let config = try SeatConfig(values: values)
            let custom = try CustomModel.parse(values["custom_models"])
            let cache = try ModelCatalogService(directory: directory, environment: environment).load()
            endpoints = Array(Set(config.seats.compactMap(\.endpoint).filter { !$0.isEmpty })).sorted()
            catalog = ModelCatalog(prices: cache.priceEntries, harnessLists: cache.harnessLists, custom: custom,
                                   seats: config.seats.map { .init(name: $0.name, model: $0.model) })
            updatedAt = cache.pricesUpdatedAt
            problem = nil
        } catch let failure as ConfigProblem {
            problem = failure.message
        } catch {
            problem = "The model list could not be read: \(error.localizedDescription)"
        }
    }

    /// Opening the pane reads the cache, and asks for a fresh list once per session when the cached one is a day old.
    func begin() {
        reload()
        guard let directory, !triedThisSession else { return }
        let service = ModelCatalogService(directory: directory, environment: environment)
        guard service.isStale((try? service.load()) ?? .init()) else { return }
        triedThisSession = true
        Task { await refresh() }
    }

    func refreshAction() -> () async -> Void { { [self] in await refresh() } }

    func refresh() async {
        guard let directory else { return }
        triedThisSession = true
        do {
            notes = try await ModelCatalogService(directory: directory, environment: environment).refresh(endpoints: endpoints).notes
        } catch {
            problem = "The model list could not be refreshed: \(error.localizedDescription)"
            return
        }
        reload()
    }

    // MARK: table

    var harnessChoices: [String] { Array(Set(catalog.entries.flatMap(\.harnesses))).sorted() }

    private var shown: [ModelCatalogEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.entries.filter { entry in
            (harnessFilter.map(entry.harnesses.contains) ?? true)
                && (query.isEmpty || entry.id.lowercased().contains(query) || entry.vendor.contains(query))
        }
        // Custom first, then what a harness reported, then the price list's own names.
        .sorted { ($0.sources.first!, $0.id) < ($1.sources.first!, $1.id) }
    }

    var title: String {
        let total = catalog.entries.count
        return shown.count == total ? "\(total) models" : "\(shown.count) of \(total) models"
    }

    var rows: [PriceTableRow] {
        shown.map { entry in
            var facts = [entry.harnesses.isEmpty ? "price list only" : entry.harnesses.joined(separator: ", ")]
            if entry.isCustom { facts.append(entry.note.isEmpty ? "custom" : "custom: \(entry.note)") }
            if !entry.inUseBy.isEmpty { facts.append("in use by \(entry.inUseBy.joined(separator: ", "))") }
            return PriceTableRow(id: entry.id, vendor: entry.vendor, detail: facts.joined(separator: " - "),
                                 prices: entry.price.map(Self.cells) ?? [], editable: entry.isCustom)
        }
    }

    /// Input, cache read, cache write, output.
    static func cells(_ price: ModelPrice) -> [String] {
        [price.input, price.cacheRead, price.cacheWrite, price.output].map { $0.map(dollars) ?? blank }
    }

    private static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...4)).locale(Locale(identifier: "en_US")))
    }

    /// The ids the seat sheet offers for a harness.
    func ids(for harness: String) -> [String] { catalog.ids(for: harness) }
}
