# Home Dashboard Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Home tab with a multi-sensor grid layout where each room tile is tappable to reveal a detail panel with temperature/humidity history charts.

**Architecture:** `HomeAssistantService` is refactored to track N sensors by entity ID (keyed by device name). The view layer has three components: an outdoor weather banner, a 2-column room tile grid, and an expandable detail panel with Charts. All data auto-discovered from HA's `/api/states` — sensors are grouped by device, rooms inferred from `friendly_name`.

**Tech Stack:** SwiftUI, Swift Charts, HA REST API

**Design reference:** `Dev/home/designs/home-designs.html` — Option B with tap-to-expand detail panel.

---

## File Structure

| File | Responsibility |
|---|---|
| `Services/HomeAssistantService.swift` | **Modify** — Replace single-sensor model with multi-sensor `RoomSensor` array + `OutdoorWeather` struct. Fetch all temperature/humidity/battery sensors and weather entity. Fetch history per sensor. |
| `Models/RoomSensor.swift` | **Create** — Data model for one room's sensors (temp, humidity, battery, entity IDs, friendly name). |
| `Views/HomeView.swift` | **Modify** — Complete rewrite: outdoor banner + 2-col grid of `RoomTileView` + expandable `RoomDetailView`. |
| `Views/RoomTileView.swift` | **Create** — Single room tile: emoji, room name, temperature, humidity, battery badge, color-coded bottom bar. |
| `Views/RoomDetailView.swift` | **Create** — Expanded detail panel: 3-stat row (temp/humid/battery), Charts temperature history, time range picker, min/max labels. |
| `Views/OutdoorBannerView.swift` | **Create** — Weather banner: condition icon, outdoor temp, wind, sunrise/sunset times. |

---

### Task 1: RoomSensor Data Model

**Files:**
- Create: `MiniWatcher/Models/RoomSensor.swift`

- [ ] **Step 1: Create the RoomSensor model**

```swift
// MiniWatcher/Models/RoomSensor.swift
import Foundation

struct RoomSensor: Identifiable {
    let id: String // device name, e.g. "meter_plus_345d"
    var friendlyName: String // e.g. "Meter Plus 345D"
    var temperature: Double?
    var humidity: Double?
    var battery: Double?
    var temperatureUnit: String = "°C"
    var temperatureEntityId: String?
    var isAvailable: Bool { temperature != nil }
    var temperatureHistory: [HAHistoryPoint] = []

    var displayName: String {
        // Strip common suffixes to get room-friendly name
        friendlyName
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

import SwiftUI

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
```

- [ ] **Step 2: Add file to Xcode project**

Open `MiniWatcher.xcodeproj/project.pbxproj` and add `RoomSensor.swift` to the Models group following the existing pattern (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase). Use next available IDs: `A1000017`/`A2000019`.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add MiniWatcher/Models/RoomSensor.swift MiniWatcher.xcodeproj/project.pbxproj
git commit -m "feat(home): add RoomSensor and OutdoorWeather data models"
```

---

### Task 2: Refactor HomeAssistantService for Multi-Sensor

**Files:**
- Modify: `MiniWatcher/Services/HomeAssistantService.swift`

- [ ] **Step 1: Replace single-sensor properties with multi-sensor model**

Replace the published properties and fetchSensors logic. The key change: instead of storing one temperature/humidity, we group sensors by device name (extracted from entity_id prefix before the last `_temperature`/`_humidity`/`_battery` suffix).

```swift
// MiniWatcher/Services/HomeAssistantService.swift
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
            isConnected = true
            errorMessage = nil
        } catch is CancellationError {
            // ignore
        } catch {
            errorMessage = error.localizedDescription
            isConnected = false
        }
    }

    private func parseStates(_ states: [HAState]) {
        // Group sensor entities by device prefix
        var sensorMap: [String: RoomSensor] = [:]
        for existing in rooms {
            sensorMap[existing.id] = existing
        }

        for state in states {
            let eid = state.entityId

            // Weather entity
            if eid.hasPrefix("weather.") {
                outdoor.condition = state.state
                outdoor.temperature = state.attributes.temperature
                outdoor.temperatureUnit = state.attributes.temperatureUnit ?? "°C"
                outdoor.humidity = state.attributes.humidity.map(Double.init)
                outdoor.windSpeed = state.attributes.windSpeed
                outdoor.windSpeedUnit = state.attributes.windSpeedUnit ?? "km/h"
                continue
            }

            // Sun entity — extract sunrise/sunset
            if eid == "sensor.sun_next_rising", let date = parseISO8601(state.state) {
                outdoor.sunrise = date
                continue
            }
            if eid == "sensor.sun_next_setting", let date = parseISO8601(state.state) {
                outdoor.sunset = date
                continue
            }

            // Sensor entities — group by device
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
        // "sensor.meter_plus_345d_temperature" -> "meter_plus_345d"
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
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: Expect build errors in `HomeView.swift` since it references old properties (`haService.temperature`, etc). That's expected — we fix it in Task 5.

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Services/HomeAssistantService.swift
git commit -m "refactor(home): multi-sensor HomeAssistantService with weather support"
```

---

### Task 3: OutdoorBannerView

**Files:**
- Create: `MiniWatcher/Views/OutdoorBannerView.swift`

- [ ] **Step 1: Create the outdoor banner**

```swift
// MiniWatcher/Views/OutdoorBannerView.swift
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
```

- [ ] **Step 2: Add file to Xcode project**

Add `OutdoorBannerView.swift` to Views group in `project.pbxproj`. Use IDs: `A1000018`/`A2000020`.

- [ ] **Step 3: Build to verify (expect errors in HomeView only)**

Run: `xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' build 2>&1 | grep "error:" | grep -v HomeView`
Expected: No errors outside HomeView.swift

- [ ] **Step 4: Commit**

```bash
git add MiniWatcher/Views/OutdoorBannerView.swift MiniWatcher.xcodeproj/project.pbxproj
git commit -m "feat(home): add OutdoorBannerView with weather and sun times"
```

---

### Task 4: RoomTileView

**Files:**
- Create: `MiniWatcher/Views/RoomTileView.swift`

- [ ] **Step 1: Create the room tile**

```swift
// MiniWatcher/Views/RoomTileView.swift
import SwiftUI

struct RoomTileView: View {
    let room: RoomSensor
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(room.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let batt = room.battery {
                    Text("🔋 \(Int(batt))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if let temp = room.temperature {
                Text(String(format: "%.1f°", temp))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(room.temperatureColor.color)
            } else {
                Text("--°")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if let humid = room.humidity {
                HStack(spacing: 4) {
                    Image(systemName: "humidity")
                        .font(.caption2)
                    Text("\(Int(humid))%")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? room.temperatureColor.color : .clear, lineWidth: 2)
        )
        .overlay(alignment: .bottom) {
            room.temperatureColor.color
                .frame(height: 3)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
        }
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

Add `RoomTileView.swift` to Views group in `project.pbxproj`. Use IDs: `A1000019`/`A2000021`.

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Views/RoomTileView.swift MiniWatcher.xcodeproj/project.pbxproj
git commit -m "feat(home): add RoomTileView with temp color and battery badge"
```

---

### Task 5: RoomDetailView

**Files:**
- Create: `MiniWatcher/Views/RoomDetailView.swift`

- [ ] **Step 1: Create the detail panel with chart**

```swift
// MiniWatcher/Views/RoomDetailView.swift
import SwiftUI
import Charts

struct RoomDetailView: View {
    let room: RoomSensor
    let history: [HAHistoryPoint]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(room.displayName)
                    .font(.headline)
                Spacer()
                Button("Close", action: onClose)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Stats row
            HStack(spacing: 0) {
                statItem(
                    value: room.temperature.map { String(format: "%.1f°", $0) } ?? "--",
                    label: "Temperature",
                    color: room.temperatureColor.color
                )
                statItem(
                    value: room.humidity.map { "\(Int($0))%" } ?? "--",
                    label: "Humidity",
                    color: .blue
                )
                statItem(
                    value: room.battery.map { "\(Int($0))%" } ?? "--",
                    label: "Battery",
                    color: .green
                )
            }

            // Chart
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature History")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Chart(history) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Temp", point.value)
                        )
                        .foregroundStyle(room.temperatureColor.color.gradient)
                        .interpolationMethod(.catmullRom)

                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value("Temp", point.value)
                        )
                        .foregroundStyle(room.temperatureColor.color.opacity(0.1).gradient)
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let v = value.as(Double.self) {
                                    Text("\(Int(v))°")
                                }
                            }
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        }
                    }
                    .frame(height: 120)

                    // Min/Max
                    if let minPoint = history.min(by: { $0.value < $1.value }),
                       let maxPoint = history.max(by: { $0.value < $1.value }) {
                        HStack {
                            Text("Low: \(String(format: "%.1f°", minPoint.value)) at \(timeString(minPoint.date))")
                            Spacer()
                            Text("High: \(String(format: "%.1f°", maxPoint.value)) at \(timeString(maxPoint.date))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No history data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .padding(20)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statItem(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

Add `RoomDetailView.swift` to Views group in `project.pbxproj`. Use IDs: `A100001A`/`A2000022`.

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Views/RoomDetailView.swift MiniWatcher.xcodeproj/project.pbxproj
git commit -m "feat(home): add RoomDetailView with chart and min/max"
```

---

### Task 6: Rewrite HomeView

**Files:**
- Modify: `MiniWatcher/Views/HomeView.swift`

- [ ] **Step 1: Replace HomeView with new grid layout**

```swift
// MiniWatcher/Views/HomeView.swift
import SwiftUI
import Charts

struct HomeView: View {
    @EnvironmentObject var haService: HomeAssistantService
    @State private var selectedRoom: RoomSensor?
    @State private var selectedHistory: [HAHistoryPoint] = []

    var body: some View {
        NavigationStack {
            Group {
                if haService.haToken.isEmpty {
                    ContentUnavailableView {
                        Label("Not Configured", systemImage: "house")
                    } description: {
                        Text("Add your Home Assistant token in Settings to get started.")
                    }
                } else if haService.isConnected {
                    connectedContent
                } else if let error = haService.errorMessage {
                    ContentUnavailableView {
                        Label("Connection Error", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await haService.fetchSensors() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Connecting to Home Assistant...")
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await haService.fetchSensors()
            }
        }
    }

    private var connectedContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Outdoor weather
                OutdoorBannerView(weather: haService.outdoor)
                    .padding(.horizontal)

                // Room grid
                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(haService.rooms) { room in
                        RoomTileView(room: room, isSelected: selectedRoom?.id == room.id)
                            .onTapGesture { toggleRoom(room) }
                    }
                }
                .padding(.horizontal)

                // Detail panel
                if let room = selectedRoom {
                    RoomDetailView(
                        room: room,
                        history: selectedHistory,
                        onClose: { withAnimation { selectedRoom = nil } }
                    )
                    .padding(.horizontal)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }

                // Compare bars
                if haService.rooms.count > 1 {
                    compareBars
                        .padding(.horizontal)
                }

                // Summary
                if !haService.rooms.isEmpty {
                    summaryRow
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    private func toggleRoom(_ room: RoomSensor) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if selectedRoom?.id == room.id {
                selectedRoom = nil
                selectedHistory = []
            } else {
                selectedRoom = room
                selectedHistory = room.temperatureHistory
                Task {
                    let history = await haService.fetchHistory(for: room)
                    if selectedRoom?.id == room.id {
                        selectedHistory = history
                    }
                }
            }
        }
    }

    private var compareBars: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Temperature")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            let maxTemp = max(
                haService.rooms.compactMap(\.temperature).max() ?? 30,
                haService.outdoor.temperature ?? 0
            )

            ForEach(haService.rooms) { room in
                compareBar(
                    label: room.displayName,
                    value: room.temperature,
                    max: maxTemp,
                    color: room.temperatureColor.color,
                    unit: "°"
                )
            }
            if let outTemp = haService.outdoor.temperature {
                compareBar(
                    label: "Outside",
                    value: outTemp,
                    max: maxTemp,
                    color: .purple,
                    unit: "°"
                )
            }
        }
        .padding(16)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func compareBar(label: String, value: Double?, max: Double, color: Color, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)

            GeometryReader { geo in
                let fraction = (value ?? 0) / max
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.gradient)
                    .frame(width: geo.size.width * max(fraction, 0.05))
                    .overlay(alignment: .leading) {
                        if let v = value {
                            Text(String(format: "%.1f%@", v, unit))
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.leading, 6)
                        }
                    }
            }
            .frame(height: 20)
        }
    }

    private var summaryRow: some View {
        let temps = haService.rooms.compactMap(\.temperature)
        let humids = haService.rooms.compactMap(\.humidity)
        let avgTemp = temps.isEmpty ? 0 : temps.reduce(0, +) / Double(temps.count)
        let avgHumid = humids.isEmpty ? 0 : humids.reduce(0, +) / Double(humids.count)
        let delta = avgTemp - (haService.outdoor.temperature ?? avgTemp)

        return HStack(spacing: 0) {
            summaryItem(value: String(format: "%.1f°", avgTemp), label: "Avg Temp")
            summaryItem(value: String(format: "%.0f%%", avgHumid), label: "Avg Humid")
            summaryItem(value: "\(haService.rooms.count)", label: "Sensors")
            summaryItem(value: String(format: "%.0f°", abs(delta)), label: "In/Out Δ")
        }
        .padding(.vertical, 12)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func summaryItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
```

- [ ] **Step 2: Build the full project**

Run: `xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Views/HomeView.swift
git commit -m "feat(home): rewrite HomeView with multi-room grid and detail panel"
```

---

### Task 7: Update SettingsView for New Service Interface

**Files:**
- Modify: `MiniWatcher/Views/SettingsView.swift`

- [ ] **Step 1: Update HA status section to show room count instead of single temperature**

In `SettingsView.swift`, find the "Home Assistant Status" section and replace:

```swift
                Section("Home Assistant Status") {
                    LabeledContent("Connected", value: haService.isConnected ? "Yes" : "No")
                    if let error = haService.errorMessage {
                        LabeledContent("Error", value: error)
                    }
                    if let temp = haService.temperature {
                        LabeledContent("Temperature", value: String(format: "%.1f%@", temp, haService.temperatureUnit))
                    }
                }
```

with:

```swift
                Section("Home Assistant Status") {
                    LabeledContent("Connected", value: haService.isConnected ? "Yes" : "No")
                    if let error = haService.errorMessage {
                        LabeledContent("Error", value: error)
                    }
                    LabeledContent("Sensors", value: "\(haService.rooms.count)")
                    ForEach(haService.rooms) { room in
                        LabeledContent(room.displayName, value: room.temperature.map { String(format: "%.1f%@", $0, room.temperatureUnit) } ?? "unavailable")
                    }
                }
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher -destination 'generic/platform=iOS' build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MiniWatcher/Views/SettingsView.swift
git commit -m "fix(settings): update HA status for multi-sensor model"
```

---

### Task 8: Build, Deploy, and Verify

**Files:** None (verification only)

- [ ] **Step 1: Build for device**

```bash
cd /Users/zhongyang/Dev/mini-watcher
xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher \
  -destination "platform=iOS,name=Tommy's iPhone" \
  -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Install on iPhone**

```bash
xcrun devicectl device install app \
  --device 79399472-07E4-58B2-9B1E-C52C69A1BAB7 \
  "$(xcodebuild -project MiniWatcher.xcodeproj -scheme MiniWatcher \
    -destination "platform=iOS,name=Tommy's iPhone" \
    -configuration Debug -showBuildSettings 2>/dev/null \
    | grep '^\s*BUILT_PRODUCTS_DIR' | head -1 | awk '{print $NF}')/MiniWatcher.app"
```

- [ ] **Step 3: Launch and verify**

```bash
xcrun devicectl device process launch \
  --device 79399472-07E4-58B2-9B1E-C52C69A1BAB7 \
  com.miniwatcher.app
```

Verify on device:
- Home tab shows outdoor weather banner at top
- Room tile(s) appear in 2-column grid (currently 1 sensor: Meter Plus 345D)
- Tapping a tile expands the detail panel with temperature history chart
- Tapping again or pressing Close collapses it
- Compare bars show if more than 1 sensor
- Summary row shows at bottom
- Pull to refresh works

- [ ] **Step 4: Commit tag**

```bash
git tag home-v2
```
