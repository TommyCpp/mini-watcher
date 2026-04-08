import SwiftUI
import Charts

struct RoomDetailView: View {
    let room: RoomSensor
    let history: [HAHistoryPoint]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(room.displayName)
                    .font(.headline)
                Spacer()
                Button("Close", action: onClose)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
