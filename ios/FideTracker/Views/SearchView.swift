import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results: [PlayerSummary] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).foregroundStyle(.secondary)
            }
            ForEach(results) { player in
                NavigationLink(value: player.fideId) {
                    PlayerRow(player: player)
                }
            }
        }
        .navigationTitle("FIDE Players")
        .navigationDestination(for: Int.self) { fideId in
            PlayerDetailView(fideId: fideId)
        }
        .searchable(text: $query, prompt: "Name or FIDE-ID")
        .onChange(of: query) { _ in scheduleSearch() }
        .overlay {
            if isLoading { ProgressView() }
            else if results.isEmpty && !query.isEmpty && errorText == nil {
                ContentUnavailableViewCompat(text: "No players found")
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { results = []; return }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // debounce
            if Task.isCancelled { return }
            await runSearch(term)
        }
    }

    private func runSearch(_ term: String) async {
        isLoading = true; errorText = nil
        defer { isLoading = false }
        do {
            results = try await FIDEDatabase.shared.search(term)
        } catch {
            errorText = error.localizedDescription
            results = []
        }
    }
}

struct PlayerRow: View {
    let player: PlayerSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let title = player.title, !title.isEmpty {
                        Text(title.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Text(player.name).font(.body)
                }
                Text([player.federation, player.active ? nil : "inactive"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let std = player.standard {
                Text("\(std)").font(.headline.monospacedDigit())
            }
        }
    }
}

/// Small shim so the file compiles on iOS 16 (ContentUnavailableView is iOS 17+).
struct ContentUnavailableViewCompat: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary)
    }
}
