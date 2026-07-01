import SwiftUI

struct TrackedView: View {
    @EnvironmentObject private var favorites: FavoritesStore

    @State private var rows: [TrackedRow] = []
    @State private var isLoading = false
    @State private var errorText: String?

    struct TrackedRow: Identifiable {
        let player: PlayerSummary
        let change: RatingChange?   // latest month-over-month change, if available
        var id: Int { player.fideId }
    }

    var body: some View {
        List {
            if favorites.ids.isEmpty {
                Text("Star players from Search or Top to track their rating here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                NavigationLink(value: row.player.fideId) {
                    HStack {
                        PlayerRow(player: row.player)
                        if let d = row.change?.standardDelta {
                            Text(d >= 0 ? "+\(d)" : "\(d)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(d >= 0 ? .green : .red)
                        }
                    }
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tracked")
        .navigationDestination(for: Int.self) { PlayerDetailView(fideId: $0) }
        .overlay { if isLoading && rows.isEmpty { ProgressView() } }
        .task(id: favorites.ids) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !favorites.ids.isEmpty else { rows = []; return }
        isLoading = true; errorText = nil
        defer { isLoading = false }
        do {
            let meta = try await FIDEDatabase.shared.meta()
            let recent = Array(meta.periods.prefix(2))  // [latest, previous]

            var built: [TrackedRow] = []
            for fideId in favorites.ids {
                let player = try await FIDEDatabase.shared.player(fideId)
                var change: RatingChange?
                if recent.count == 2 {
                    change = try? await FIDEDatabase.shared.change(
                        fideId, from: recent[1], to: recent[0]
                    )
                }
                built.append(TrackedRow(player: summary(from: player), change: change))
            }
            rows = built
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func summary(from d: PlayerDetail) -> PlayerSummary {
        PlayerSummary(fideId: d.fideId, name: d.name, federation: d.federation,
                      title: d.title, standard: d.standard, rapid: d.rapid,
                      blitz: d.blitz, active: d.active)
    }
}
