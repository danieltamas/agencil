# Agencil brand brief

The designer agent produces the app icon, the menu bar glyph, the menu bar animation frames and the
backdrop mesh. The owner picks one of three concepts (decision D4 in `docs/PLAN.md`).

## The idea

Several minds, one verdict. Seats on a ring, synapses between them, a core where they converge. It should
read as thinking, not as a network diagram or a logo of any vendor.

## Family (match the siblings)

`Brand/icon-app.svg` follows the house icon frame used by MacMax, Bton and RMJ:
- `viewBox="0 0 1024 1024"`, width and height 1024.
- The body: a rounded square `x=100 y=100 width=824 height=824 rx=186`, filled with a dark diagonal gradient (Agencil: 1C1A33 to 08080F).
- Shadow: `feDropShadow dx=0 dy=18 stdDeviation=22 flood-opacity=.45`.
- An inner hairline: a rect at 102/820/rx184, white stroke, opacity .07, width 4.
- The mark sits inside that body: strokes 56 to 64 wide with round caps, a gradient from the brand stops (6E56F8, A98BFF, FF9BD2) with one accent in `accent2` (F5C451).

`Brand/icon-menubar.svg`:
- `viewBox="0 0 36 36"`, black on transparent (a template image), with a comment saying so.
- Strokes 2.6 to 3.
- It must read at 16 px: 3 to 5 nodes and one center.
- No thin chords under 2 px at 18 pt.

## Concepts to draw (all three, then the owner picks)

1. **Ring and core**: five seat nodes on a 270 degree ring, open at the bottom, as a nod to MacMax's dial. Curved synapses run from each node to a filled core; one synapse in `accent2` marks the dissent that was kept.
2. **Converging arcs**: three arcs from different directions bend into one point, like a brain fold seen from above. The point is the verdict.
3. **Council table**: a hexagon of nodes with one node lit and chords to two others, an ask moving through the council.

For each concept:
- The app icon at 1024, 128, 32 and 16 px (PNG from `scripts/render-icons.sh`).
- The menu bar glyph at 18 pt on light and dark menu bars.
- One sheet `Brand/concepts/<n>.png` with all sizes side by side.

## Derived assets (after the pick)

- **Menu bar animation**: 14 frames, `Brand/menubar-frames/<n>.svg`, built from the glyph's own geometry. The nodes light in turn and a spark travels along one synapse.
  - They are pre-rendered to PDFs and tinted at runtime per look.
  - This frame pipeline is new work: Bton's `MenuBarIcon` only draws a static working icon and a short sync ripple. Agencil reuses Bton's icon plumbing, not a frame set.
- **Backdrop mesh**: `Brand/mesh.svg`, a sparse field of nodes and curved links. Rendered once into `Support/Resources/mesh.png` at 2x panel size and shown at 4% opacity in the lit look only.
- **Registry icon**: `icons/agencil.png` in danieltamas/registry, 256 x 256 PNG, at most 64 KiB, `iconShape: macos`.
- **Vendor marks**: `Brand/vendors/*.svg` (simple-icons, monochrome) for the harnesses Agencil runs. Used as template images, never recolored to the vendor's brand.

## Acceptance

- The three concepts are rendered, and the owner's pick is recorded in `docs/PLAN.md` D4.
- `scripts/render-icons.sh` is deterministic (`SOURCE_DATE_EPOCH=315532800`): running it twice gives byte-identical `Support/AppIcon.icns`, `Support/MenuBarIcon.pdf` and the frame PDFs.
- The glyph at 16 px shows every node as a separate blob, checked on the rendered PNG.
- `accent`, `accent2` and `brand` in `docs/DESIGN.md` and the registry `hue` match the final icon in the same commit.
- No vendor logo, letterform or trademark is part of the Agencil mark.
