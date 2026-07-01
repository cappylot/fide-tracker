import SwiftUI

struct TopView: View {
    @State private var players: [PlayerSummary] = []
    @State private var ratingType: RatingType = .standard
    @State private var federation = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                Picker("Rating", selection: $ratingType) {
                    ForEach(RatingType.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Federation filter (e.g. GER)", text: $federation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section {
                ForEach(Array(players.enumerated()), id: \.element.id) { index, player in
                    NavigationLink(value: player.fideId) {
                        HStack {
                            Text("\(index + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                            PlayerRow(player: player)
                        }
                    }
                }
            }
        }
        .navigationTitle("Top Players")
        .navigationDestination(for: Int.self) { PlayerDetailView(fideId: $0) }
        .overlay { if isLoading { ProgressView() } }
        .task { await load() }
        .onChange(of: ratingType) { _ in Task { await load() } }
        .onSubmit { Task { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true; errorText = nil
        defer { isLoading = false }
        do {
            players = try await FIDEDatabase.shared.top(
                type: ratingType,
                limit: 100,
                federation: federation.trimmingCharacters(in: .whitespaces),
                activeOnly: true
            )
        } catch {
            errorText = error.localizedDescription
        }
    }
}
