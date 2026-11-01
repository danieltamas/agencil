import SwiftUI

/// One line of the price table: the model, a second line of facts, and the price cells already formatted.
struct PriceTableRow: Identifiable, Equatable {
    let id: String
    let vendor: String
    let detail: String
    /// One formatted cell per column; empty when the model has no price.
    let prices: [String]
    var editable = false
}

/// A scrolling table of models and their prices: vendor mark and the whole id (it wraps, never cut) on the left, fixed
/// price columns on the right, the header held still above the rows. Only an `editable` row can be pressed.
struct PriceTable: View {
    let columns: [String]
    let rows: [PriceTableRow]
    var empty = "Nothing matches"
    let edit: (String) -> Void

    private static let cell: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: Space.s) {
                Eyebrow(text: "Model").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { title in
                    Eyebrow(text: title).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        .frame(width: Self.cell, alignment: .trailing)
                }
            }
            .padding(.vertical, Space.s)
            RowDivider()
            if rows.isEmpty {
                Text(empty).font(.house.meta).foregroundStyle(Theme.textTertiary).padding(.vertical, Space.xl)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            line(row)
                            RowDivider()
                        }
                    }
                }
                .frame(height: Size.priceTable)
            }
        }
    }

    @ViewBuilder private func line(_ row: PriceTableRow) -> some View {
        if row.editable {
            Button { edit(row.id) } label: { content(row).padding(.horizontal, Space.m) }
                .buttonStyle(RowPressStyle())
                .padding(.horizontal, -Space.m)
                .accessibilityLabel("Edit \(row.id)")
        } else {
            content(row)
        }
    }

    private func content(_ row: PriceTableRow) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                VendorMark(vendor: row.vendor).padding(.top, Space.xxs)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(row.id).font(.house.mono).foregroundStyle(Theme.textPrimary).detailLines()
                    Text(row.detail).font(.house.meta).foregroundStyle(Theme.textTertiary).detailLines()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.prices.isEmpty {
                Text("no price").font(.house.meta).foregroundStyle(Theme.textTertiary)
                    .frame(width: Self.cell * CGFloat(columns.count) + Space.s * CGFloat(columns.count - 1), alignment: .trailing)
                    .padding(.top, Space.xxs)
            } else {
                ForEach(Array(row.prices.enumerated()), id: \.offset) { _, price in
                    Text(price).font(.house.mono).foregroundStyle(price == PriceTable.blank ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: Self.cell, alignment: .trailing)
                        .padding(.top, Space.xxs)
                }
            }
        }
        .padding(.vertical, Space.m)
    }

    /// The cell of a price the list does not have (a cache price, usually): a dash, never a guess.
    static let blank = "-"
}
