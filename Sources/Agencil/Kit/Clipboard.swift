import AppKit

/// The system pasteboard, the one way a view asks for what the owner copied.
enum Clipboard {
    /// A copied image (a screenshot taken with Ctrl-Cmd-Shift-4, an image copied from a page), as PNG or TIFF bytes.
    @MainActor static func imageData() -> Data? {
        let board = NSPasteboard.general
        return board.data(forType: .png) ?? board.data(forType: .tiff)
    }
}
