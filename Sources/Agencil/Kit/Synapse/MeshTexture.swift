import AppKit
import SwiftUI

/// The static neural mesh behind the glows, in the `agencil` look only (docs/DESIGN.md "Visual layer" 6).
/// A still image rendered at build time from `Brand/mesh.svg`; never animated.
enum MeshTexture {
    static let opacity = 0.04

    @MainActor static func visible(in look: Look) -> Bool { look == .agencil }

    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "mesh", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct MeshOverlay: View {
    var body: some View {
        if MeshTexture.visible(in: Appearance.shared.look), let image = MeshTexture.image {
            Image(nsImage: image).resizable().scaledToFill().opacity(MeshTexture.opacity).allowsHitTesting(false)
        }
    }
}
