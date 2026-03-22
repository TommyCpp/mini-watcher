import Foundation

struct ServiceInfo: Codable, Identifiable {
    let label: String
    let pid: Int?
    let status: String
    let exitCode: Int
    let cpuPercent: Double?
    let memoryMb: Double?
    let uptimeSeconds: Double?
    let keepAlive: Bool
    let runAtLoad: Bool
    let program: String
    let source: String

    var id: String { label }
    var isRunning: Bool { status == "running" }
    var canControl: Bool { label != "com.miniwatcher.server" }

    var shortLabel: String {
        let parts = label.split(separator: ".")
        if parts.count <= 2 { return label }
        return parts.dropFirst(2).joined(separator: ".")
    }

    var formattedUptime: String {
        guard let s = uptimeSeconds else { return "" }
        let t = Int(s)
        if t < 60 { return "\(t)s" }
        if t < 3600 { return "\(t/60)m \(t%60)s" }
        if t < 86400 { return "\(t/3600)h \(t%3600/60)m" }
        return "\(t/86400)d \(t%86400/3600)h"
    }

    enum CodingKeys: String, CodingKey {
        case label, pid, status, program, source
        case exitCode = "exit_code"
        case cpuPercent = "cpu_percent"
        case memoryMb = "memory_mb"
        case uptimeSeconds = "uptime_seconds"
        case keepAlive = "keep_alive"
        case runAtLoad = "run_at_load"
    }
}
