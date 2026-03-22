import SwiftUI
import Charts

struct MetricChartPanel: View {
    let title: String
    let data: [(Date, Double)]
    let color: Color
    let unit: String

    private var currentValue: Double { data.last?.1 ?? 0 }
    private var minValue: Double { data.map(\.1).min() ?? 0 }
    private var maxValue: Double { data.map(\.1).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(currentValue, specifier: "%.1f")\(unit)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
            }

            if data.isEmpty {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart {
                    ForEach(data, id: \.0) { date, value in
                        LineMark(
                            x: .value("Time", date),
                            y: .value(title, value)
                        )
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                    }
                    AreaMark(
                        x: .value("Time", data.last!.0),
                        yStart: .value("Min", minValue),
                        yEnd: .value("Max", maxValue)
                    )
                    .opacity(0)
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
                                Text("\(v, specifier: "%.0f")\(unit)")
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .frame(height: 120)

                HStack {
                    Label("Min: \(minValue, specifier: "%.1f")\(unit)", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("Max: \(maxValue, specifier: "%.1f")\(unit)", systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}
