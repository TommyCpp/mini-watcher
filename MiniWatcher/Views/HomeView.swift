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
                OutdoorBannerView(weather: haService.outdoor)
                    .padding(.horizontal)

                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(haService.rooms) { room in
                        RoomTileView(room: room, isSelected: selectedRoom?.id == room.id)
                            .onTapGesture { toggleRoom(room) }
                    }
                }
                .padding(.horizontal)

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

                if haService.rooms.count > 1 {
                    compareBars
                        .padding(.horizontal)
                }

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
                    maxValue: maxTemp,
                    color: room.temperatureColor.color,
                    unit: "°"
                )
            }
            if let outTemp = haService.outdoor.temperature {
                compareBar(
                    label: "Outside",
                    value: outTemp,
                    maxValue: maxTemp,
                    color: .purple,
                    unit: "°"
                )
            }
        }
        .padding(16)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func compareBar(label: String, value: Double?, maxValue: Double, color: Color, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .trailing)

            GeometryReader { geo in
                let fraction = (value ?? 0) / maxValue
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
