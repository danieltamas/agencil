import AppKit
import SwiftUI

extension View {
    /// Sets `panelVisible` from the window this view is in: false when the window is closed, hidden or fully covered,
    /// so the panel's scenes stop (docs/DESIGN.md "Pause and reduce").
    func trackPanelVisibility() -> some View { modifier(PanelVisibilityTracker()) }
}

private struct PanelVisibilityTracker: ViewModifier {
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .environment(\.panelVisible, visible)
            .background(WindowWatcher { visible = $0 })
    }
}

private struct WindowWatcher: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) { view.changed = changed }
}

private final class WatcherView: NSView {
    var changed: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { report(false); return }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report(self?.isOnScreen ?? false) }
            })
        }
        report(isOnScreen)
    }

    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func report(_ visible: Bool) { changed?(visible) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
    }
}
