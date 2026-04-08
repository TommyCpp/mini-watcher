import SwiftUI

struct OutdoorBannerView: View {
    let weather: OutdoorWeather

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                Text(weather.conditionIcon)
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        if let temp = weather.temperature {
                            Text(String(format: "%.0f°", temp))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                        }
                        Text(weather.temperatureUnit)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(conditionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let sunrise = weather.sunrise {
                    Label(timeString(sunrise), systemImage: "sunrise.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let sunset = weather.sunset {
                    Label(timeString(sunset), systemImage: "sunset.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color(white: 0.1), Color(red: 0.05, green: 0.08, blue: 0.15)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var conditionText: String {
        var parts: [String] = []
        parts.append(weather.condition.replacingOccurrences(of: "-", with: " ").capitalized)
        if let wind = weather.windSpeed {
            parts.append("Wind \(Int(wind)) \(weather.windSpeedUnit)")
        }
        return parts.joined(separator: " · ")
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
