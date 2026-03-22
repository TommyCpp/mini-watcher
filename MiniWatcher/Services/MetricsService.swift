import Foundation
import SwiftUI

@MainActor
class MetricsService: ObservableObject {
    @Published var metrics: SystemMetrics?
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var dockerContainers: [DockerContainer] = []
    @Published var dockerAvailable: Bool? = nil

    @AppStorage("serverHost") var serverHost = "192.168.1.100"
    @AppStorage("serverPort") var serverPort = "8085"

    private var pollingTask: Task<Void, Never>?

    var baseURL: String {
        "http://\(serverHost):\(serverPort)"
    }

    init() {
        startPolling()
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                async let metricsResult: Void = fetchMetrics()
                async let dockerResult: Void = fetchDocker()
                _ = await (metricsResult, dockerResult)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func fetchMetrics() async {
        guard let url = URL(string: "\(baseURL)/metrics") else {
            errorMessage = "Invalid URL"
            isConnected = false
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                errorMessage = "Bad response"
                isConnected = false
                return
            }
            let decoded = try JSONDecoder().decode(SystemMetrics.self, from: data)
            metrics = decoded
            isConnected = true
            errorMessage = nil
        } catch is CancellationError {
            // Task cancelled, ignore
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }
    }

    func fetchDocker() async {
        guard let url = URL(string: "\(baseURL)/docker") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(DockerResponse.self, from: data)
            dockerContainers = decoded.containers
            dockerAvailable = decoded.available
        } catch is CancellationError {
            // ignore
        } catch {
            // On first fetch, mark unavailable rather than staying nil forever
            if dockerAvailable == nil { dockerAvailable = false }
            // subsequent errors: keep previous state silently
        }
    }

    func fetchHistory(range: HistoryRange) async throws -> [HistoryDataPoint] {
        guard let url = URL(string: "\(baseURL)/history?range=\(range.rawValue)") else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        return try decoder.decode([HistoryDataPoint].self, from: data)
    }

    func fetchServices() async throws -> [ServiceInfo] {
        guard let url = URL(string: "\(baseURL)/services") else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([ServiceInfo].self, from: data)
    }

    func controlService(label: String, action: String) async throws {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        guard let url = URL(string: "\(baseURL)/services/\(encoded)/\(action)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    func controlContainer(id: String, action: DockerAction, runtime: String) async throws {
        guard let url = URL(string: "\(baseURL)/docker/\(id)/\(action.rawValue)?runtime=\(runtime)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            struct ErrorBody: Decodable { let detail: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
                ?? "Container action failed"
            throw NSError(domain: "DockerError", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        // Immediately refresh so the UI reflects the new container status
        await fetchDocker()
    }

    func testConnection() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            struct HealthResponse: Codable { let status: String }
            let health = try JSONDecoder().decode(HealthResponse.self, from: data)
            return health.status == "ok"
        } catch {
            return false
        }
    }
}
