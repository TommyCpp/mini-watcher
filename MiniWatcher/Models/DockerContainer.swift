import Foundation

struct DockerResponse: Codable {
    let available: Bool
    let containers: [DockerContainer]
}

struct DockerContainer: Codable, Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let cpuPercent: Double
    let memoryMb: Double
    let memoryLimitMb: Double
    let memoryPercent: Double
    let runtime: String  // "docker" or "podman"

    /// Docker-convention 12-char display ID
    var shortId: String { String(id.prefix(12)) }

    enum CodingKeys: String, CodingKey {
        case id, name, image, status, runtime
        case cpuPercent = "cpu_percent"
        case memoryMb = "memory_mb"
        case memoryLimitMb = "memory_limit_mb"
        case memoryPercent = "memory_percent"
    }
}

enum DockerAction: String {
    case start, stop, restart
}
