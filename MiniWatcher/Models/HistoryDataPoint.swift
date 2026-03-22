import Foundation

struct HistoryDataPoint: Codable, Identifiable {
    let id = UUID()
    let ts: Double
    let cpu: Double
    let memory: Double
    let netIn: Double
    let netOut: Double

    var date: Date { Date(timeIntervalSince1970: ts) }

    enum CodingKeys: String, CodingKey {
        case ts, cpu, memory
        case netIn = "net_in"
        case netOut = "net_out"
    }
}
