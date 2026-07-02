import Foundation
import SwiftUI

/// The last few search queries, most recent first, shown in SearchView before
/// the user types. Like FavoritesStore this is per-user device state,
/// persisted in UserDefaults.
@MainActor
final class SearchHistoryStore: ObservableObject {
    @Published private(set) var entries: [String] = []

    private let key = "search_history"
    private let capacity = 5

    init() {
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Inserts a query at the front, moving an existing entry (compared
    /// case-insensitively) to the front instead of duplicating it.
    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(trimmed, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(entries, forKey: key)
    }
}
