import AppKit
import SwiftUI

/// The mark of the company that trained a seat's model, drawn as a template and tinted with a theme token, never
/// in the vendor's own colors. A vendor without a bundled mark gets a symbol. Adding a vendor is
/// `Brand/vendors/<vendor>.svg`, one line in `scripts/render-icons.sh` and one entry in `files` below.
struct VendorMark: View {
    /// Vendor names as the seat config spells them, to the file in `Support/Vendors/` (without `.pdf`).
    static let files: [String: String] = ["anthropic": "claude", "openai": "openai"]
    static let symbols: [String: String] = [
        "nvidia": "bolt.horizontal", "zhipu": "sparkle", "deepseek": "water.waves", "xiaomi": "circle.hexagongrid",
        "google": "diamond", "meta": "infinity", "mistral": "wind",
    ]
    static let unknownSymbol = "cpu"
    @MainActor private static var loaded: [String: NSImage] = [:]

    let vendor: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Group {
            if let image = Self.image(for: vendor) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: Self.symbols[vendor] ?? Self.unknownSymbol).resizable().scaledToFit()
            }
        }
        .foregroundStyle(color)
        .frame(width: Size.vendorMark, height: Size.vendorMark)
        .accessibilityHidden(true)
    }

    /// The bundled mark; a build folder (and `swift test`) reads `Support/Vendors/` from the working directory.
    @MainActor static func image(for vendor: String) -> NSImage? {
        guard let file = files[vendor] else { return nil }
        if let image = loaded[file] { return image }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Vendors")
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Support/Vendors")
        for directory in [bundled, local].compactMap({ $0 }) {
            let url = directory.appendingPathComponent(file + ".pdf")
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                loaded[file] = image
                return image
            }
        }
        return nil
    }
}
