import AgencilCore
import AppKit
import SwiftUI

/// What `scripts/perf.sh` runs: the app with a stub feed and no broker, one scenario per process (docs/DESIGN.md "Budget").
@MainActor enum PerfScenario: String {
    case closed, open, live, menubar

    static var requested: PerfScenario? {
        guard CommandLine.arguments.contains("--perf") else { return nil }
        return ProcessInfo.processInfo.environment["AGENCIL_PERF"].flatMap(PerfScenario.init(rawValue:))
    }

    /// The panel's store: nothing live except in `live`, where a 5-seat sitting is running.
    func store() -> PanelStore {
        PanelStore(data: DemoPanel.build(live: self == .live, extraSeats: self == .live ? 2 : 0))
    }

    /// Starts once the app's run loop is up.
    func launch(_ store: PanelStore) {
        DispatchQueue.main.async { self.start(store) }
    }

    /// `open` and `live` show the panel in a window; `live` emits one claim every 5 s.
    private func start(_ store: PanelStore) {
        guard self == .open || self == .live else { return }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: Size.panelWidth, height: Size.panelMaxHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PanelView(store: store))
        window.makeKeyAndOrderFront(nil)
        guard self == .live else { return }
        let seats = store.ringSeats
        var claim = 0
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                claim += 1
                store.feedRing(.claim(id: "claim-\(claim)", seat: seats[claim % seats.count]))
            }
        }
    }
}
