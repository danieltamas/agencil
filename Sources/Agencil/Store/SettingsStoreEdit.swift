import AgencilCore
import Foundation

/// Opening a row in its sheet and deleting from it. Saving goes through `save`, which updates while `editing` is set.
extension SettingsStore {
    func sheetTitle(_ kind: SheetKind) -> String { editing == nil ? kind.title : "Edit \(kind.rawValue)" }

    func sheetPrimaryTitle() -> String { editing == nil ? "Create" : "Save" }

    /// Opens the sheet for the `index`th row of the list as it is shown, filled from the file as it is now. The row is
    /// bound to what was shown (a seat or council by name, a route by its whole entry): a file that no longer holds
    /// it opens nothing and refreshes the list. A file that cannot be read opens nothing; `reload` puts its reason on the pane.
    func startEdit(_ kind: SheetKind, index: Int) {
        guard let editor else { return }
        let drafts: (seats: [SeatDraft], councils: [CouncilDraft], routes: [RouteDraft])
        do { drafts = try editor.current() } catch {
            reload()
            return
        }
        startSheet(kind)
        switch kind {
        case .seat:
            guard seatNames.indices.contains(index), let seat = drafts.seats.first(where: { $0.name == seatNames[index] }) else { return changedSinceShown() }
            seatForm = SeatForm(name: seat.name, harness: seat.harness, model: seat.model, endpoint: seat.endpoint ?? "", pin: seat.pin ?? "",
                                cap: seat.capSeconds.map(String.init) ?? "", vendor: seat.vendor ?? "", plan: seat.plan ?? "",
                                hosted: seat.hosted, role: seat.role ?? "")
            editing = .seat(was: seat)
        case .council:
            guard councilRows.indices.contains(index), let council = drafts.councils.first(where: { $0.name == councilRows[index].name })
            else { return changedSinceShown() }
            councilForm = CouncilForm(name: council.name, seats: council.seats, rule: council.rule, quorum: council.quorum.map(String.init) ?? "",
                                      spare: council.spare, synthesizer: council.synthesizer)
            editing = .council(was: council)
        case .route:
            guard shownRoutes.indices.contains(index), drafts.routes.indices.contains(index), drafts.routes[index] == shownRoutes[index]
            else { return changedSinceShown() }
            let route = drafts.routes[index]
            routeForm = RouteForm(callers: route.callers.joined(separator: ", "), target: route.target, hops: route.hopLimit.map(String.init) ?? "")
            editing = .route(index: index, was: route)
        }
        presenting = kind
    }

    /// The Delete press of an Edit sheet. A refusal (the object is still used) stays in `problems["form"]` and the sheet stays open.
    func deleteAction(_ kind: SheetKind) -> () async -> Void {
        { [self] in delete(kind) }
    }

    private func delete(_ kind: SheetKind) {
        guard let editor, let target = editing else { return }
        do {
            switch (kind, target) {
            case (.seat, .seat(let was)): try editor.remove(seat: was.name)
            case (.council, .council(let was)): try editor.remove(council: was.name)
            case (.route, .route(let index, let was)): try editor.remove(routeAt: index, was: was)
            default: return
            }
        } catch {
            problems = (error as? SheetProblems)?.fields ?? ["form": error.localizedDescription]
            confirmingDelete = false
            return
        }
        problems = [:]
        confirmingDelete = false
        reload()
        presenting = nil
    }
}
