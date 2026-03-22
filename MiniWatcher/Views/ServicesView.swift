import SwiftUI

struct ServicesView: View {
    @EnvironmentObject private var metricsService: MetricsService

    @State private var services: [ServiceInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?

    private var running: [ServiceInfo] { services.filter(\.isRunning) }
    private var stopped: [ServiceInfo] { services.filter { !$0.isRunning } }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && services.isEmpty {
                    ProgressView("Loading services...")
                } else if let error = errorMessage, services.isEmpty {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await loadServices() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            if !running.isEmpty {
                                serviceSection("Running", systemImage: "circle.fill", color: .green, services: running)
                            }
                            if !stopped.isEmpty {
                                serviceSection("Stopped", systemImage: "circle.fill", color: .red, services: stopped)
                            }
                            if services.isEmpty {
                                Text("No custom services found")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 200)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Services")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            pollingTask = Task {
                while !Task.isCancelled {
                    await loadServices()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    private func serviceSection(_ title: String, systemImage: String, color: Color, services: [ServiceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 8))
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("(\(services.count))")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            ForEach(services) { service in
                ServiceCardView(
                    service: service,
                    onStart: { await controlService(label: service.label, action: "start") },
                    onStop: { await controlService(label: service.label, action: "stop") }
                )
            }
        }
    }

    private func loadServices() async {
        if services.isEmpty { isLoading = true }
        do {
            services = try await metricsService.fetchServices()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func controlService(label: String, action: String) async {
        do {
            try await metricsService.controlService(label: label, action: action)
            try? await Task.sleep(for: .seconds(1))
        } catch {}
        await loadServices()
    }
}
