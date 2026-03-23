import Foundation

struct TmuxSession: Codable, Identifiable {
    let name: String
    let windows: Int
    let created: Double  // whole-number Unix epoch; Double for Date conversion
    let attached: Bool

    var id: String { name }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
}

struct TmuxResponse: Codable {
    let available: Bool
    let sessions: [TmuxSession]
}
