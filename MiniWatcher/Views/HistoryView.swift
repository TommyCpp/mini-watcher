import SwiftUI

enum HistoryRange: String, CaseIterable {
    case tenMin = "10m"
    case oneHour = "1h"
    case twoHours = "2h"
    case sixHours = "6h"
    case twelveHours = "12h"
    case oneDay = "1d"
    case threeDays = "3d"
    case sevenDays = "7d"

    var label: String { rawValue }
}

struct HistoryView: View {
    @EnvironmentObject private var metricsService: MetricsService

    @State private var selectedRange: HistoryRange = .oneHour
    @State private var dataPoints: [HistoryDataPoint] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var cpuData: [(Date, Double)] {
        dataPoints.map { ($0.date, $0.cpu) }
    }

    private var memoryData: [(Date, Double)] {
        dataPoints.map { ($0.date, $0.memory) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Picker("Range", selection: $selectedRange) {
                        ForEach(HistoryRange.allCases, id: \.self) { range in
                            Text(range.label).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let error = errorMessage {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        MetricChartPanel(
                            title: "CPU",
                            data: cpuData,
                            color: .blue,
                            unit: "%"
                        )

                        MetricChartPanel(
                            title: "Memory",
                            data: memoryData,
                            color: .purple,
                            unit: "%"
                        )

                        NetworkChartPanel(data: dataPoints)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: selectedRange) {
            await loadHistory()
        }
    }

    private func loadHistory() async {
        isLoading = true
        errorMessage = nil
        do {
            dataPoints = try await metricsService.fetchHistory(range: selectedRange)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
