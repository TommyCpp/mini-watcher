import Foundation
import SwiftUI

struct HAState: Decodable {
    let entityId: String
    let state: String
    let attributes: HAAttributes
    let lastChanged: String

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case state
        case attributes
        case lastChanged = "last_changed"
    }
}

struct HAAttributes: Decodable {
    let unitOfMeasurement: String?
    let friendlyName: String?
    let deviceClass: String?
    let windSpeed: Double?
    let windSpeedUnit: String?
    let windBearing: Double?
    let temperature: Double?
    let temperatureUnit: String?
    let humidity: Int?
    let cloudCoverage: Double?

    enum CodingKeys: String, CodingKey {
        case unitOfMeasurement = "unit_of_measurement"
        case friendlyName = "friendly_name"
        case deviceClass = "device_class"
        case windSpeed = "wind_speed"
        case windSpeedUnit = "wind_speed_unit"
        case windBearing = "wind_bearing"
        case temperature
        case temperatureUnit = "temperature_unit"
        case humidity
        case cloudCoverage = "cloud_coverage"
    }
}

struct HAHistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

@MainActor
class HomeAssistantService: ObservableObject {
    @Published var rooms: [RoomSensor] = []
    @Published var outdoor = OutdoorWeather()
    @Published var isConnected = false
    @Published var errorMessage: String?

    @AppStorage("haHost") var haHost = "localhost"
    @AppStorage("haPort") var haPort = "8123"
    @AppStorage("haToken") var haToken = ""

    private var pollingTask: Task<Void, Never>?

    var baseURL: String {
        "http://\(haHost):\(haPort)"
    }

    init() {
        startPolling()
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await fetchSensors()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func fetchSensors() async {
        guard !haToken.isEmpty else {
            errorMessage = "No HA token configured"
            isConnected = false
            return
        }
        guard let url = URL(string: "\(baseURL)/api/states") else {
            errorMessage = "Invalid URL"
            isConnected = false
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(haToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Auth failed (check token)"
                isConnected = false
                return
            }
            let states = try JSONDecoder().decode([HAState].self, from: data)
            parseStates(states)

            let entityIds = rooms.compactMap(\.temperatureEntityId)
            let areas = await fetchAreas(for: entityIds)
            if !areas.isEmpty {
                rooms = rooms.map { room in
                    var updated = room
                    if let eid = room.temperatureEntityId, let area = areas[eid] {
                        updated.area = area
                    }
                    return updated
                }
            }

            isConnected = true
            errorMessage = nil
        } catch is CancellationError {
            // ignore
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }
    }

    private struct AreaEntry: Decodable {
        let entity_id: String
        let area: String
    }

    private func fetchAreas(for entityIds: [String]) async -> [String: String] {
        guard !haToken.isEmpty, !entityIds.isEmpty else { return [:] }
        guard let url = URL(string: "\(baseURL)/api/template") else { return [:] }

        // Builds a JSON array of {entity_id, area} for every temperature sensor.
        // We return a list (not a dict) because HA's Jinja2 doesn't reliably
        // support **-unpacking into dict() — list + namespace is the safe pattern.
        let template = """
        {% set ns = namespace(items=[]) %}\
        {% for s in states.sensor if s.attributes.device_class == 'temperature' %}\
        {% set ns.items = ns.items + [{'entity_id': s.entity_id, 'area': (area_name(s.entity_id) or '')}] %}\
        {% endfor %}\
        {{ ns.items | tojson }}
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(haToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["template": template]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return [:] }
        request.httpBody = encoded

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            let entries = try JSONDecoder().decode([AreaEntry].self, from: data)
            var result: [String: String] = [:]
            for entry in entries where !entry.area.isEmpty {
                result[entry.entity_id] = entry.area
            }
            return result
        } catch {
            return [:]
        }
    }

    private func parseStates(_ states: [HAState]) {
        var sensorMap: [String: RoomSensor] = [:]
        for existing in rooms {
            sensorMap[existing.id] = existing
        }

        for state in states {
            let eid = state.entityId

            if eid.hasPrefix("weather.") {
                outdoor.condition = state.state
                outdoor.temperature = state.attributes.temperature
                outdoor.temperatureUnit = state.attributes.temperatureUnit ?? "°C"
                outdoor.humidity = state.attributes.humidity.map(Double.init)
                outdoor.windSpeed = state.attributes.windSpeed
                outdoor.windSpeedUnit = state.attributes.windSpeedUnit ?? "km/h"
                continue
            }

            if eid == "sensor.sun_next_rising", let date = parseISO8601(state.state) {
                outdoor.sunrise = date
                continue
            }
            if eid == "sensor.sun_next_setting", let date = parseISO8601(state.state) {
                outdoor.sunset = date
                continue
            }

            guard eid.hasPrefix("sensor."),
                  let deviceClass = state.attributes.deviceClass,
                  ["temperature", "humidity", "battery"].contains(deviceClass) else { continue }

            let deviceId = extractDeviceId(from: eid, deviceClass: deviceClass)
            var room = sensorMap[deviceId] ?? RoomSensor(
                id: deviceId,
                friendlyName: state.attributes.friendlyName ?? deviceId
            )

            let value = Double(state.state)
            switch deviceClass {
            case "temperature":
                room.temperature = value
                room.temperatureUnit = state.attributes.unitOfMeasurement ?? "°C"
                room.temperatureEntityId = eid
                room.friendlyName = state.attributes.friendlyName ?? room.friendlyName
            case "humidity":
                room.humidity = value
            case "battery":
                room.battery = value
            default: break
            }

            sensorMap[deviceId] = room
        }

        rooms = Array(sensorMap.values).sorted { ($0.temperature ?? 0) > ($1.temperature ?? 0) }
    }

    private func extractDeviceId(from entityId: String, deviceClass: String) -> String {
        let prefix = "sensor."
        var name = String(entityId.dropFirst(prefix.count))
        let suffixes = ["_temperature", "_humidity", "_battery"]
        for suffix in suffixes {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    private func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    func fetchHistory(for room: RoomSensor) async -> [HAHistoryPoint] {
        guard let entityId = room.temperatureEntityId,
              let url = URL(string: "\(baseURL)/api/history/period?filter_entity_id=\(entityId)&minimal_response&no_attributes") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(haToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let history = try JSONDecoder().decode([[HAState]].self, from: data)
            guard let points = history.first else { return [] }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            return points.compactMap { point in
                guard let val = Double(point.state),
                      let date = formatter.date(from: point.lastChanged) else { return nil }
                return HAHistoryPoint(date: date, value: val)
            }
        } catch {
            return []
        }
    }
}
