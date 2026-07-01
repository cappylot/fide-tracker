import Foundation

// These mirror the FastAPI schemas 1:1 so JSONDecoder maps them directly.

struct PlayerSummary: Codable, Identifiable, Hashable {
    let fideId: Int
    let name: String
    let federation: String?
    let title: String?
    let standard: Int?
    let rapid: Int?
    let blitz: Int?
    let active: Bool

    var id: Int { fideId }

    enum CodingKeys: String, CodingKey {
        case fideId = "fide_id"
        case name, federation, title, standard, rapid, blitz, active
    }
}

struct PlayerDetail: Codable, Identifiable {
    let fideId: Int
    let name: String
    let federation: String?
    let title: String?
    let sex: String?
    let birthYear: Int?
    let latestPeriod: String?
    let standard: Int?
    let rapid: Int?
    let blitz: Int?
    let active: Bool

    var id: Int { fideId }

    enum CodingKeys: String, CodingKey {
        case fideId = "fide_id"
        case name, federation, title, sex, active
        case birthYear = "birth_year"
        case latestPeriod = "latest_period"
        case standard, rapid, blitz
    }
}

struct HistoryPoint: Codable, Identifiable {
    let period: String
    let standard: Int?
    let rapid: Int?
    let blitz: Int?

    var id: String { period }

    /// "2026-06" -> a Date on the 1st of that month, for charting on a time axis.
    var date: Date {
        let parts = period.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts.first
        comps.month = parts.count > 1 ? parts[1] : 1
        comps.day = 1
        return Calendar.current.date(from: comps) ?? Date()
    }
}

struct RatingHistory: Codable {
    let fideId: Int
    let name: String
    let points: [HistoryPoint]

    enum CodingKeys: String, CodingKey {
        case fideId = "fide_id"
        case name, points
    }
}

struct RatingChange: Codable {
    let fideId: Int
    let name: String
    let fromPeriod: String
    let toPeriod: String
    let standardDelta: Int?
    let rapidDelta: Int?
    let blitzDelta: Int?
    let standardFrom: Int?
    let standardTo: Int?

    enum CodingKeys: String, CodingKey {
        case fideId = "fide_id"
        case name
        case fromPeriod = "from_period"
        case toPeriod = "to_period"
        case standardDelta = "standard_delta"
        case rapidDelta = "rapid_delta"
        case blitzDelta = "blitz_delta"
        case standardFrom = "standard_from"
        case standardTo = "standard_to"
    }
}

struct Meta: Codable {
    let latestPeriod: String?
    let periods: [String]
    let playerCount: Int

    enum CodingKeys: String, CodingKey {
        case latestPeriod = "latest_period"
        case periods
        case playerCount = "player_count"
    }
}

/// Which rating list the UI is currently showing.
enum RatingType: String, CaseIterable, Identifiable {
    case standard, rapid, blitz
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}
