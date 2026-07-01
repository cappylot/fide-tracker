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

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { TopView() }
                .tabItem { Label("Top", systemImage: "trophy") }

            NavigationStack { TrackedView() }
                .tabItem { Label("Tracked", systemImage: "star") }
        }
    }
}
