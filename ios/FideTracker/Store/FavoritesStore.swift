import Foundation
import SwiftUI

/// The list of tracked ("favourite") players lives on-device, not on the
/// server — it's per-user preference. Persisted in UserDefaults.
///
/// The "notify me when a tracked player's rating changes" idea from the plan
/// is a client concern: on refresh, diff each tracked player's two most recent
/// snapshots via the /change endpoint and surface the delta (see TrackedView).
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var ids: [Int] = []

    private let key = "tracked_fide_ids"

    init() {
        ids = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
    }

    func isTracked(_ fideId: Int) -> Bool { ids.contains(fideId) }

    func toggle(_ fideId: Int) {
        if let idx = ids.firstIndex(of: fideId) {
            ids.remove(at: idx)
        } else {
            ids.append(fideId)
        }
        UserDefaults.standard.set(ids, forKey: key)
    }
}
