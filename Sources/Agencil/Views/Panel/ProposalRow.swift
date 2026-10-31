import SwiftUI

/// One open learn proposal: the council change, its evidence and the reviewer's word, with the owner's decision.
struct ProposalRow: View {
    let proposal: ProposalItem
    let approve: () async -> Void
    let reject: () async -> Void
    let review: () async -> Void

    var body: some View {
        HoverCard(accent: proposal.endorsed ? Theme.ok : Theme.warn, action: nil) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Chip(text: proposal.status, color: proposal.endorsed ? Theme.ok : Theme.warn)
                    Text(proposal.title).font(.house.rowTitle).foregroundStyle(Theme.textPrimary).titleLines()
                    Spacer(minLength: 0)
                }
                Text(proposal.detail).font(.house.meta).foregroundStyle(Theme.textTertiary).detailLines()
                HStack(spacing: Space.s) {
                    Spacer(minLength: 0)
                    if proposal.needsReview {
                        AsyncPress(id: "review:\(proposal.id)", action: review) { running, press in
                            ChipButton(title: running ? "Reviewing..." : "Review", action: press)
                        }
                    }
                    AsyncPress(id: "reject:\(proposal.id)", action: reject) { running, press in
                        ChipButton(title: running ? "..." : "Reject", action: press)
                    }
                    if proposal.endorsed {
                        AsyncPress(id: "approve:\(proposal.id)", action: approve) { running, press in
                            ChipButton(title: running ? "..." : "Approve", action: press)
                        }
                    }
                }
            }
        }
    }
}
