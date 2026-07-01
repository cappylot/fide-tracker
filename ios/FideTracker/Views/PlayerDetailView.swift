import SwiftUI
import Charts

struct PlayerDetailView: View {
    let fideId: Int
    @EnvironmentObject private var favorites: FavoritesStore

    @State private var detail: PlayerDetail?
    @State private var history: [HistoryPoint] = []
    @State private var ratingType: RatingType = .standard
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        List {
            if let detail {
                headerSection(detail)
                chartSection
                historySection
            } else if isLoading {
                ProgressView()
            } else if let errorText {
                Text(errorText).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(detail?.name ?? "Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    favorites.toggle(fideId)
                } label: {
                    Image(systemName: favorites.isTracked(fideId) ? "star.fill" : "star")
                }
            }
        }
        .task { await load() }
    }

    // MARK: Sections

    private func headerSection(_ d: PlayerDetail) -> some View {
        Section {
            LabeledContent("FIDE-ID", value: String(d.fideId))
            if let fed = d.federation { LabeledContent("Federation", value: fed) }
            if let title = d.title, !title.isEmpty {
                LabeledContent("Title", value: title.uppercased())
            }
            if let year = d.birthYear { LabeledContent("Born", value: String(year)) }
            if let p = d.latestPeriod { LabeledContent("Latest list", value: p) }
            if !d.active { LabeledContent("Status", value: "Inactive") }
        }
    }

    private var chartSection: some View {
        Section {
            Picker("Rating", selection: $ratingType) {
                ForEach(RatingType.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            let series = seriesPoints()
            if series.count >= 2 {
                Chart(series) { point in
                    LineMark(x: .value("Month", point.date),
                             y: .value("Rating", point.rating))
                    .interpolationMethod(.monotone)
                    PointMark(x: .value("Month", point.date),
                              y: .value("Rating", point.rating))
                    .symbolSize(20)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 220)

                if let delta = allTimeDelta() {
                    DeltaLabel(title: "Since first list", value: delta)
                }
            } else {
                Text("Not enough history yet for a chart.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Rating history")
        }
    }

    private var historySection: some View {
        Section("Monthly snapshots") {
            ForEach(Array(history.reversed())) { p in
                HStack {
                    Text(p.period).font(.subheadline.monospacedDigit())
                    Spacer()
                    Text(valueString(for: p))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Helpers

    private func value(_ p: HistoryPoint) -> Int? {
        switch ratingType {
        case .standard: return p.standard
        case .rapid: return p.rapid
        case .blitz: return p.blitz
        }
    }

    private func valueString(for p: HistoryPoint) -> String {
        value(p).map(String.init) ?? "—"
    }

    private func seriesPoints() -> [ChartPoint] {
        history.compactMap { p in value(p).map { ChartPoint(date: p.date, rating: $0) } }
    }

    private func allTimeDelta() -> Int? {
        let pts = seriesPoints()
        guard let first = pts.first?.rating, let last = pts.last?.rating else { return nil }
        return last - first
    }

    private func load() async {
        isLoading = true; errorText = nil
        defer { isLoading = false }
        do {
            async let d = FIDEDatabase.shared.player(fideId)
            async let h = FIDEDatabase.shared.history(fideId)
            detail = try await d
            history = try await h.points
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct DeltaLabel: View {
    let title: String
    let value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value >= 0 ? "+\(value)" : "\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(value >= 0 ? .green : .red)
        }
    }
}

/// A single charted point. Identifiable by date, since Swift key paths can't
/// address tuple elements (`\.0` is invalid).
struct ChartPoint: Identifiable {
    let date: Date
    let rating: Int
    var id: Date { date }
}
