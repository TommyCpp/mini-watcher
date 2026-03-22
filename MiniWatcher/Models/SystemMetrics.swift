import Foundation

struct SystemMetrics: Codable {
    let timestamp: String
    let hostname: String
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let disk: DiskMetrics
    let processes: [ProcessInfo]
    let processSummary: ProcessSummary

    enum CodingKeys: String, CodingKey {
        case timestamp, hostname, cpu, memory, disk, processes
        case processSummary = "process_summary"
    }
}

struct CPUMetrics: Codable {
    let usagePercent: Double
    let coreCount: Int
    let perCorePercent: [Double]
    let loadAvg1m: Double
    let loadAvg5m: Double
    let loadAvg15m: Double

    enum CodingKeys: String, CodingKey {
        case usagePercent = "usage_percent"
        case coreCount = "core_count"
        case perCorePercent = "per_core_percent"
        case loadAvg1m = "load_avg_1m"
        case loadAvg5m = "load_avg_5m"
        case loadAvg15m = "load_avg_15m"
    }
}

struct MemoryMetrics: Codable {
    let totalGb: Double
    let usedGb: Double
    let availableGb: Double
    let usagePercent: Double

    enum CodingKeys: String, CodingKey {
        case totalGb = "total_gb"
        case usedGb = "used_gb"
        case availableGb = "available_gb"
        case usagePercent = "usage_percent"
    }
}

struct DiskMetrics: Codable {
    let totalGb: Double
    let usedGb: Double
    let freeGb: Double
    let usagePercent: Double

    enum CodingKeys: String, CodingKey {
        case totalGb = "total_gb"
        case usedGb = "used_gb"
        case freeGb = "free_gb"
        case usagePercent = "usage_percent"
    }
}

struct ProcessInfo: Codable, Identifiable {
    let pid: Int
    let name: String
    let cpuPercent: Double
    let memoryPercent: Double
    let memoryMb: Double

    var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid, name
        case cpuPercent = "cpu_percent"
        case memoryPercent = "memory_percent"
        case memoryMb = "memory_mb"
    }
}

struct ProcessSummary: Codable {
    let total: Int
    let running: Int
    let sleeping: Int
}
