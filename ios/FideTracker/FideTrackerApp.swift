import SwiftUI

@main
struct FideTrackerApp: App {
    @StateObject private var favorites = FavoritesStore()

    var body: some Scene {
        WindowGroup {
            // A View owns the .task; Scenes don't support .task directly.
            LoaderView()
                .environmentObject(favorites)
        }
    }
}

/// Loads (and, on first launch, downloads) the local FIDE database, then shows
/// the app. Displays progress and an error/retry state.
struct LoaderView: View {
    private enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .ready:
                RootView()
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text("Couldn't load the database").font(.headline)
                    Text(message)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading FIDE database…").foregroundStyle(.secondary)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            try await FIDEDatabase.shared.initialize()
            state = .ready
            // Check for a newer monthly release in the background.
            Task { try? await FIDEDatabase.shared.syncIfNeeded() }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

enum AppSection: CaseIterable, Identifiable {
    case search, top, tracked

    var id: Self { self }

    var title: String {
        switch self {
        case .search: return "Search"
        case .top: return "Top"
        case .tracked: return "Tracked"
        }
    }

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .top: return "trophy"
        case .tracked: return "star"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .search: SearchView()
        case .top: TopView()
        case .tracked: TrackedView()
        }
    }
}

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // iPhone (and iPad Slide Over) keeps the tab bar; full-screen iPad
        // and Mac get a sidebar instead.
        if horizontalSizeClass == .regular {
            SplitRootView()
        } else {
            TabRootView()
        }
    }
}

struct TabRootView: View {
    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.destination }
                    .tabItem { Label(section.title, systemImage: section.icon) }
            }
        }
    }
}

struct SplitRootView: View {
    @State private var selection: AppSection? = .search

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
            }
            .navigationTitle("FIDE Tracker")
        } detail: {
            NavigationStack { (selection ?? .search).destination }
                // Give each section its own stack so pushed player pages
                // don't leak across sidebar switches.
                .id(selection)
        }
    }
}
