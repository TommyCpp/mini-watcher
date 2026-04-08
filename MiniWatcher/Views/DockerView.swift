import SwiftUI

struct DockerView: View {
    @EnvironmentObject private var metricsService: MetricsService
    @State private var actionError: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                switch metricsService.dockerAvailable {
                case nil:
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case false:
                    ContentUnavailableView(
                        "No Runtime Available",
                        systemImage: "shippingbox",
                        description: Text("Neither Docker nor Podman is available on this host.")
                    )
                case true:
                    if metricsService.dockerContainers.isEmpty {
                        ContentUnavailableView(
                            "No Containers",
                            systemImage: "shippingbox",
                            description: Text("No containers found on Docker or Podman.")
                        )
                    } else {
                        containerList
                    }
                }
            }
            .navigationTitle("Containers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Action Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown error")
        }
    }

    private var containerList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(metricsService.dockerContainers) { container in
                    ContainerRowView(container: container) { action in
                        await performAction(container: container, action: action)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func performAction(container: DockerContainer, action: DockerAction) async {
        do {
            try await metricsService.controlContainer(id: container.id, action: action, runtime: container.runtime)
        } catch {
            actionError = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Container Row

private struct ContainerRowView: View {
    let container: DockerContainer
    let onAction: (DockerAction) async -> Void
    @State private var isActioning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name + image + runtime badge + status badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.subheadline.weight(.semibold))
                    Text(container.image)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusBadge(status: container.status)
                    RuntimeBadge(runtime: container.runtime)
                }
            }

            // CPU
            HStack {
                Text("CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", container.cpuPercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(container.cpuPercent > 80 ? .red : .primary)
            }

            // Memory bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("MEM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f / %.0f MB (%.1f%%)",
                                container.memoryMb,
                                container.memoryLimitMb,
                                container.memoryPercent))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(container.memoryPercent > 85 ? Color.red : Color.blue)
                            .frame(width: geo.size.width * CGFloat(min(container.memoryPercent, 100.0) / 100),
                                   height: 6)
                    }
                }
                .frame(height: 6)
            }

            // Action buttons
            HStack(spacing: 8) {
                ActionButton(label: "Start",
                             systemImage: "play.fill",
                             disabled: isActioning || container.status == "running" || container.status == "paused") {
                    isActioning = true
                    defer { isActioning = false }
                    await onAction(.start)
                }
                ActionButton(label: "Stop",
                             systemImage: "stop.fill",
                             disabled: isActioning || container.status != "running") {
                    isActioning = true
                    defer { isActioning = false }
                    await onAction(.stop)
                }
                ActionButton(label: "Restart",
                             systemImage: "arrow.clockwise",
                             disabled: isActioning || container.status != "running") {
                    isActioning = true
                    defer { isActioning = false }
                    await onAction(.restart)
                }
            }
        }
        .padding(12)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Runtime Badge

private struct RuntimeBadge: View {
    let runtime: String

    var body: some View {
        Text(runtime.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: String

    private var color: Color {
        switch status {
        case "running": return .green
        case "paused": return .yellow
        default: return .gray
        }
    }

    var body: some View {
        Text(status)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let label: String
    let systemImage: String
    let disabled: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .controlSize(.small)
    }
}
