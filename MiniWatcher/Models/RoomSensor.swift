import Foundation
import SwiftUI

struct RoomSensor: Identifiable {
    let id: String // device name, e.g. "meter_plus_345d"
    var friendlyName: String // e.g. "Meter Plus 345D"
    var area: String? = nil
    var temperature: Double?
    var humidity: Double?
    var battery: Double?
    var temperatureUnit: String = "°C"
    var temperatureEntityId: String?
    var isAvailable: Bool { temperature != nil }
    var temperatureHistory: [HAHistoryPoint] = []

    var displayName: String {
        if let area = area, !area.isEmpty {
            return area
        }
        return friendlyName
            .replacingOccurrences(of: " Temperature", with: "")
            .replacingOccurrences(of: " Humidity", with: "")
            .replacingOccurrences(of: " Battery", with: "")
    }

    var temperatureColor: RoomTemperatureColor {
        guard let temp = temperature else { return .cool }
        switch temp {
        case ..<18: return .cool
        case ..<23: return .comfy
        case ..<26: return .warm
        default: return .hot
        }
    }
}

enum RoomTemperatureColor {
    case cool, comfy, warm, hot

    var color: Color {
        switch self {
        case .cool: .blue
        case .comfy: .green
        case .warm: .orange
        case .hot: .red
        }
    }
}

struct OutdoorWeather {
    var temperature: Double?
    var temperatureUnit: String = "°C"
    var humidity: Double?
    var condition: String = "unknown"
    var windSpeed: Double?
    var windSpeedUnit: String = "km/h"
    var sunrise: Date?
    var sunset: Date?

    var conditionIcon: String {
        switch condition {
        case "sunny": return "☀️"
        case "clear-night": return "🌙"
        case "partlycloudy": return "⛅"
        case "cloudy": return "☁️"
        case "rainy": return "🌧️"
        case "snowy": return "❄️"
        case "lightning": return "⛈️"
        case "fog": return "🌫️"
        default: return "🌤️"
        }
    }
}
