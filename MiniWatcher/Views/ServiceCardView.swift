import SwiftUI

struct ServiceCardView: View {
    let service: ServiceInfo
    let onStart: () async -> Void
    let onStop: () async -> Void

    @State private var isExpanded = false
    @State private var isActioning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed header
            Button {
                withAnimation(.spring(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(service.isRunning ? Color.green : Color.red)
                        .frame(width: 9, height: 9)

                    VStack(alignment: .leading, spacing: 3) {
                        // Full label for identification
                        Text(service.label)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        HStack(spacing: 6) {
                            // Source badge inline
                            Text(service.source == "LaunchDaemons" ? "Daemon" : "Agent")
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.indigo.opacity(0.15), in: Capsule())
                                .foregroundStyle(.indigo)

                            Text(service.program)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if service.isRunning {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let cpu = service.cpuPercent {
                                HStack(spacing: 3) {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.blue)
                                    Text(String(format: "%.1f%%", cpu))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.blue)
                                }
                            }
                            if let mem = service.memoryMb {
                                HStack(spacing: 3) {
                                    Image(systemName: "memorychip")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.purple)
                                    Text(String(format: "%.0fM", mem))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.purple)
                                }
                            }
                        }
                    } else {
                        if service.exitCode != 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                                Text("Exit \(service.exitCode)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                Divider().padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 14) {
                    // Stats row
                    if service.isRunning {
                        HStack(spacing: 0) {
                            statItem("PID", value: service.pid.map(String.init) ?? "—",
                                     icon: "number", iconColor: .secondary)
                            Spacer()
                            statItem("Uptime", value: service.formattedUptime,
                                     icon: "clock", iconColor: .secondary)
                            Spacer()
                            statItem("CPU", value: service.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                                     icon: "cpu", iconColor: .blue, valueColor: .blue)
                            Spacer()
                            statItem("Memory", value: service.memoryMb.map { String(format: "%.0f MB", $0) } ?? "—",
                                     icon: "memorychip", iconColor: .purple, valueColor: .purple)
                        }
                    } else {
                        statItem("Exit Code", value: "\(service.exitCode)",
                                 icon: service.exitCode == 0 ? "checkmark.circle" : "xmark.circle",
                                 iconColor: service.exitCode != 0 ? .red : .green,
                                 valueColor: service.exitCode != 0 ? .red : .primary)
                    }

                    // Info rows
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(icon: "tag", label: "Label", value: service.label)
                        infoRow(icon: "terminal", label: "Binary", value: service.program)
                        infoRow(icon: "folder", label: "Source", value: service.source)
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    // Badges
                    HStack(spacing: 8) {
                        badge(service.source == "LaunchDaemons" ? "Daemon" : "Agent", color: .indigo)
                        if service.keepAlive { badge("KeepAlive", color: .orange) }
                        if service.runAtLoad { badge("RunAtLoad", color: .teal) }
                    }

                    // Start / Stop button
                    if service.canControl {
                        Button {
                            isActioning = true
                            Task {
                                if service.isRunning { await onStop() } else { await onStart() }
                                isActioning = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if isActioning {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Image(systemName: service.isRunning ? "stop.fill" : "play.fill")
                                }
                                Text(service.isRunning ? "Stop Service" : "Start Service")
                                    .font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                service.isRunning ? Color.red.opacity(0.15) : Color.green.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(service.isRunning ? .red : .green)
                        }
                        .disabled(isActioning)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func statItem(_ label: String, value: String, icon: String, iconColor: Color, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(iconColor)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(valueColor)
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
