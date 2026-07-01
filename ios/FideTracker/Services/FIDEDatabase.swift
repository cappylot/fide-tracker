import Foundation
import GRDB

// A player is inactive when its FIDE flag contains "i": "i" (inactive) or
// "wi" (woman-inactive). "" and "w" (active woman) are active.
fileprivate func fideIsActive(_ flag: String?) -> Bool {
    !((flag ?? "").lowercased().contains("i"))
}

// MARK: - Row types (GRDB decoding)

fileprivate struct SummaryRow: Decodable, FetchableRecord {
    var fideId: Int
    var name: String
    var federation: String?
    var title: String?
    var flag: String?
    var standard: Int?
    var rapid: Int?
    var blitz: Int?

    enum CodingKeys: String, CodingKey {
        case fideId = "fide_id"
        case name, federation, title, flag, standard, rapid, blitz
    }

    var summary: PlayerSummary {
        PlayerSummary(fideId: fideId, name: name, federation: federation, title: title,
                      standard: standard, rapid: rapid, blitz: blitz, active: fideIsActive(flag))
    }
}

fileprivate struct DetailRow: Decodable, FetchableRecord {
    var fideId: Int
    var name: String
    var federation: String?
    var title: String?
    var sex: String?
    var birthYear: Int?
    var flag: String?
    var standard: Int?
    var rapid: Int?
    var blitz: Int?
    var latestPeriod: String?

    enum CodingKeys: String, CodingKey {
        case fideId = "fide_id"
        case name, federation, title, sex, flag, standard, rapid, blitz
        case birthYear = "birth_year"
        case latestPeriod = "latest_period"
    }

    var detail: PlayerDetail {
        PlayerDetail(fideId: fideId, name: name, federation: federation, title: title,
                     sex: sex, birthYear: birthYear, latestPeriod: latestPeriod,
                     standard: standard, rapid: rapid, blitz: blitz, active: fideIsActive(flag))
    }
}

fileprivate struct HistoryRow: Decodable, FetchableRecord {
    var period: String
    var standard: Int?
    var rapid: Int?
    var blitz: Int?
}

fileprivate struct SnapRow: Decodable, FetchableRecord {
    var standard: Int?
    var rapid: Int?
    var blitz: Int?
}

/// Queries the local FIDE SQLite database downloaded from GitHub Releases.
///
/// On first launch it downloads the latest `fide.db` from the repo's releases;
/// afterwards `syncIfNeeded()` compares the latest release tag against the one
/// we last downloaded and pulls a new database only when a new monthly list
/// has been published.
///
/// This is an `actor`, so all reads are serialized automatically; GRDB's
/// `DatabaseQueue` is itself thread-safe, so queries are safe and fast.
actor FIDEDatabase {
    static let shared = FIDEDatabase()

    /// Set this to your GitHub "owner/repo" (the fork you push the workflow to).
    private let repoSlug = "YOUR_USER/fide-tracker"

    private let tagDefaultsKey = "fide_db_release_tag"
    private var dbQueue: DatabaseQueue?

    private var documentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var dbURL: URL { documentURL.appendingPathComponent("fide.db") }

    enum DBError: LocalizedError {
        case notInitialized
        case notFound
        case releaseUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Database is still loading."
            case .notFound: return "Player not found."
            case .releaseUnavailable(let m): return m
            }
        }
    }

    // MARK: - Lifecycle

    /// Downloads the database if it isn't present, then opens it.
    func initialize() async throws {
        if !FileManager.default.fileExists(atPath: dbURL.path) {
            let release = try await fetchLatestRelease()
            try await downloadDatabase(from: release.assetURL)
            UserDefaults.standard.set(release.tag, forKey: tagDefaultsKey)
        }
        try openDatabase()
    }

    /// Checks GitHub for a newer release and, if the tag differs from what we
    /// last downloaded, replaces the local database. Safe to call in the
    /// background; runs serialized on the actor.
    func syncIfNeeded() async throws {
        let release = try await fetchLatestRelease()
        let current = UserDefaults.standard.string(forKey: tagDefaultsKey)
        guard release.tag != current else { return }
        try await downloadDatabase(from: release.assetURL)
        UserDefaults.standard.set(release.tag, forKey: tagDefaultsKey)
        try openDatabase()
    }

    private func openDatabase() throws {
        var config = Configuration()
        config.readonly = true  // the app never writes; the DB is built in CI
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        // Sanity check that the schema is present.
        try queue.read { db in
            _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM player")
        }
        dbQueue = queue
    }

    // MARK: - Release download

    private struct ReleaseInfo { let tag: String; let assetURL: URL }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DBError.releaseUnavailable(
                "No FIDE database release found yet. Run the GitHub Action first."
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == "fide.db" }),
              let urlString = asset["browser_download_url"] as? String,
              let assetURL = URL(string: urlString)
        else {
            throw DBError.releaseUnavailable("Latest release is missing the fide.db asset.")
        }
        return ReleaseInfo(tag: tag, assetURL: assetURL)
    }

    /// Streams the (large) database to a temp file, then atomically moves it
    /// into place. Uses `download(from:)` rather than `data(from:)` so we never
    /// hold the whole file in memory.
    private func downloadDatabase(from assetURL: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: assetURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DBError.releaseUnavailable("Failed to download the database file.")
        }
        // Release any open handle before replacing the file on disk.
        dbQueue = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: dbURL.path) {
            try fm.removeItem(at: dbURL)
        }
        try fm.moveItem(at: tempURL, to: dbURL)
    }

    private func requireQueue() throws -> DatabaseQueue {
        guard let queue = dbQueue else { throw DBError.notInitialized }
        return queue
    }

    // MARK: - Queries

    func meta() async throws -> Meta {
        let queue = try requireQueue()
        return try queue.read { db in
            let periods = try String.fetchAll(
                db, sql: "SELECT DISTINCT period FROM rating_snapshot ORDER BY period DESC"
            )
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM player") ?? 0
            return Meta(latestPeriod: periods.first, periods: periods, playerCount: count)
        }
    }

    func search(_ query: String, limit: Int = 25) async throws -> [PlayerSummary] {
        let queue = try requireQueue()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return try queue.read { db in
            let latest = try String.fetchOne(db, sql: "SELECT MAX(period) FROM rating_snapshot")

            let rows: [SummaryRow]
            if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber), let id = Int64(trimmed) {
                rows = try SummaryRow.fetchAll(db, sql: """
                    SELECT p.fide_id, p.name, p.federation, p.title, p.flag,
                           s.standard, s.rapid, s.blitz
                    FROM player p
                    LEFT JOIN rating_snapshot s ON s.fide_id = p.fide_id AND s.period = ?
                    WHERE p.fide_id = ?
                    LIMIT ?
                    """, arguments: [latest, id, limit])
            } else {
                // In SQLite, NULLs sort last under DESC, so unrated players fall
                // to the bottom without an explicit NULLS LAST clause.
                rows = try SummaryRow.fetchAll(db, sql: """
                    SELECT p.fide_id, p.name, p.federation, p.title, p.flag,
                           s.standard, s.rapid, s.blitz
                    FROM player p
                    LEFT JOIN rating_snapshot s ON s.fide_id = p.fide_id AND s.period = ?
                    WHERE p.name LIKE ?
                    ORDER BY s.standard DESC
                    LIMIT ?
                    """, arguments: [latest, "%\(trimmed)%", limit])
            }
            return rows.map(\.summary)
        }
    }

    func player(_ fideId: Int) async throws -> PlayerDetail {
        let queue = try requireQueue()
        return try queue.read { db in
            guard let row = try DetailRow.fetchOne(db, sql: """
                SELECT p.fide_id, p.name, p.federation, p.title, p.sex, p.birth_year, p.flag,
                       s.standard, s.rapid, s.blitz, s.period AS latest_period
                FROM player p
                LEFT JOIN rating_snapshot s ON s.fide_id = p.fide_id
                WHERE p.fide_id = ?
                ORDER BY s.period DESC
                LIMIT 1
                """, arguments: [fideId])
            else { throw DBError.notFound }
            return row.detail
        }
    }

    func history(_ fideId: Int) async throws -> RatingHistory {
        let queue = try requireQueue()
        return try queue.read { db in
            guard let name = try String.fetchOne(
                db, sql: "SELECT name FROM player WHERE fide_id = ?", arguments: [fideId]
            ) else { throw DBError.notFound }

            let rows = try HistoryRow.fetchAll(db, sql: """
                SELECT period, standard, rapid, blitz
                FROM rating_snapshot WHERE fide_id = ? ORDER BY period ASC
                """, arguments: [fideId])
            let points = rows.map {
                HistoryPoint(period: $0.period, standard: $0.standard, rapid: $0.rapid, blitz: $0.blitz)
            }
            return RatingHistory(fideId: fideId, name: name, points: points)
        }
    }

    func change(_ fideId: Int, from: String, to: String) async throws -> RatingChange {
        let queue = try requireQueue()
        return try queue.read { db in
            guard let name = try String.fetchOne(
                db, sql: "SELECT name FROM player WHERE fide_id = ?", arguments: [fideId]
            ) else { throw DBError.notFound }

            let sql = "SELECT standard, rapid, blitz FROM rating_snapshot WHERE fide_id = ? AND period = ?"
            guard let a = try SnapRow.fetchOne(db, sql: sql, arguments: [fideId, from]),
                  let b = try SnapRow.fetchOne(db, sql: sql, arguments: [fideId, to])
            else { throw DBError.notFound }

            func delta(_ x: Int?, _ y: Int?) -> Int? {
                guard let x, let y else { return nil }
                return y - x
            }
            return RatingChange(
                fideId: fideId, name: name, fromPeriod: from, toPeriod: to,
                standardDelta: delta(a.standard, b.standard),
                rapidDelta: delta(a.rapid, b.rapid),
                blitzDelta: delta(a.blitz, b.blitz),
                standardFrom: a.standard, standardTo: b.standard
            )
        }
    }

    func top(type: RatingType = .standard,
             limit: Int = 100,
             federation: String? = nil,
             activeOnly: Bool = true) async throws -> [PlayerSummary] {
        let queue = try requireQueue()
        // Safe interpolation: `type.rawValue` is a fixed enum value, not input.
        let col = type.rawValue
        return try queue.read { db in
            var sql = """
                SELECT p.fide_id, p.name, p.federation, p.title, p.flag,
                       s.standard, s.rapid, s.blitz
                FROM player p
                JOIN rating_snapshot s ON s.fide_id = p.fide_id
                WHERE s.period = (SELECT MAX(period) FROM rating_snapshot)
                  AND s.\(col) IS NOT NULL
                """
            var args: [(any DatabaseValueConvertible)?] = []
            if let federation, !federation.isEmpty {
                sql += " AND p.federation = ?"
                args.append(federation.uppercased())
            }
            if activeOnly {
                // Exclude "i" and "wi" (both contain "i"); keep "" and "w".
                sql += " AND (p.flag IS NULL OR p.flag NOT LIKE '%i%')"
            }
            sql += " ORDER BY s.\(col) DESC LIMIT ?"
            args.append(limit)

            let rows = try SummaryRow.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map(\.summary)
        }
    }
}
