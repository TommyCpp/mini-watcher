import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var service: MetricsService
    @State private var sortOrder: ProcessSortOrder = .cpu

    var body: some View {
        NavigationStack {
            Group {
                if let m = service.metrics {
                    ScrollView {
                        VStack(spacing: 20) {

                            // Connection status
                            HStack {
                                Circle()
                                    .fill(service.isConnected ? .green : .red)
                                    .frame(width: 10, height: 10)
                                Text(m.hostname)
                                    .font(.body.weight(.medium))
                                Spacer()
                                Text(m.processSummary.total.description + " processes")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)

                            // Gauges
                            HStack(spacing: 24) {
                                GaugeRingView(
                                    title: "CPU",
                                    value: m.cpu.usagePercent,
                                    subtitle: "\(m.cpu.coreCount) cores"
                                )
                                GaugeRingView(
                                    title: "Memory",
                                    value: m.memory.usagePercent,
                                    subtitle: String(format: "%.1f / %.1f GB", m.memory.usedGb, m.memory.totalGb)
                                )
                                GaugeRingView(
                                    title: "Disk",
                                    value: m.disk.usagePercent,
                                    subtitle: String(format: "%.0f / %.0f GB", m.disk.usedGb, m.disk.totalGb)
                                )
                            }
                            .padding(.horizontal)

                            // Load averages
                            HStack(spacing: 16) {
                                loadLabel("1m", value: m.cpu.loadAvg1m)
                                loadLabel("5m", value: m.cpu.loadAvg5m)
                                loadLabel("15m", value: m.cpu.loadAvg15m)
                            }
                            .padding(.horizontal)

                            // Process list
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Top Processes")
                                    .font(.headline)
                                    .padding(.horizontal)

                                ProcessListView(processes: m.processes, sortOrder: $sortOrder)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                    .scrollDismissesKeyboard(.immediately)
                } else if let error = service.errorMessage {
                    ContentUnavailableView {
                        Label("Connection Error", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await service.fetchMetrics() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView("Connecting...")
                }
            }
            .navigationTitle("Mini-Watcher")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func loadLabel(_ period: String, value: Double) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%.2f", value))
                .font(.body.monospacedDigit().weight(.medium))
            Text("Load \(period)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(in: RoundedRectangle(cornerRadius: 10))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10))
    }
}
