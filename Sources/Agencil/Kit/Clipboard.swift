import AppKit
import SwiftUI

/// The system pasteboard, the one way a view asks for what the owner copied.
enum Clipboard {
    /// Puts `text` on the pasteboard as plain text, replacing what was there.
    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A copied image (a screenshot taken with Ctrl-Cmd-Shift-4, an image copied from a page), as PNG or TIFF bytes.
    /// Files copied in the Finder, as absolute paths.
    @MainActor static func filePaths() -> [String] {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    @MainActor static func imageData() -> Data? {
        let board = NSPasteboard.general
        return board.data(forType: .png) ?? board.data(forType: .tiff)
    }
}

/// Cmd-V carrying an image or files, which a focused text editor swallows without telling its parents.
private struct PasteCatcher: ViewModifier {
    let perform: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v" else { return event }
                    let board = NSPasteboard.general
                    // Copied files win (the Finder adds their names as text too); an image wins only with no text beside it,
                    // so text still pastes into the editor as it always did.
                    let image = board.data(forType: .png) != nil || board.data(forType: .tiff) != nil
                    guard !Clipboard.filePaths().isEmpty || (image && board.string(forType: .string) == nil) else { return event }
                    perform()
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    /// Runs `perform` for a paste of an image or files, wherever the focus is inside the app window.
    func onPasteOfMedia(perform: @escaping () -> Void) -> some View { modifier(PasteCatcher(perform: perform)) }
}
