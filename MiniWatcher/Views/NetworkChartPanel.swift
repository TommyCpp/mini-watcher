import SwiftUI
import Charts

struct NetworkChartPanel: View {
    let data: [HistoryDataPoint]

    private func formatBytes(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }

    private var currentIn: Double { data.last?.netIn ?? 0 }
    private var currentOut: Double { data.last?.netOut ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Network")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Label(formatBytes(currentIn), systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Label(formatBytes(currentOut), systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if data.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart {
                    ForEach(data) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Bytes/s", point.netIn),
                            series: .value("Direction", "In")
                        )
                        .foregroundStyle(.green)
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("Bytes/s", point.netOut),
                            series: .value("Direction", "Out")
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                            .font(.system(size: 11))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatBytes(v))
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .frame(height: 120)

                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("In").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text("Out").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}
