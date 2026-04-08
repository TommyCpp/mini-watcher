import SwiftUI

struct TmuxView: View {
    @EnvironmentObject private var metricsService: MetricsService
    @State private var actionError: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Group {
                switch metricsService.tmuxAvailable {
                case nil:
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case false:
                    ContentUnavailableView(
                        "tmux Not Available",
                        systemImage: "terminal",
                        description: Text("tmux is not installed or not running on this host.")
                    )
                case true:
                    if metricsService.tmuxSessions.isEmpty {
                        ContentUnavailableView(
                            "No tmux Sessions",
                            systemImage: "terminal",
                            description: Text("No active tmux sessions found on the server.")
                        )
                    } else {
                        sessionList
                    }
                }
            }
            .navigationTitle("tmux")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Kill Failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown error")
        }
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(metricsService.tmuxSessions) { session in
                    SessionRowView(session: session) {
                        await performKill(session: session)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func performKill(session: TmuxSession) async {
        do {
            try await metricsService.killTmuxSession(session.name)
        } catch {
            actionError = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Session Row

private struct SessionRowView: View {
    let session: TmuxSession
    let onKill: () async -> Void
    @State private var isKilling = false
    @State private var showKillConfirm = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: name + metadata
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text("\(session.windows) \(session.windows == 1 ? "window" : "windows")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.createdDate.relativeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Right: attached badge + kill button
            VStack(alignment: .trailing, spacing: 6) {
                AttachedBadge(attached: session.attached)
                Button(role: .destructive) {
                    showKillConfirm = true
                } label: {
                    Label("Kill", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isKilling)
            }
        }
        .padding(12)
        .background(in: RoundedRectangle(cornerRadius: 16))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        .confirmationDialog(
            "Kill session \"\(session.name)\"?",
            isPresented: $showKillConfirm,
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                Task {
                    isKilling = true
                    defer { isKilling = false }
                    await onKill()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Attached Badge

private struct AttachedBadge: View {
    let attached: Bool

    var body: some View {
        Text(attached ? "attached" : "detached")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((attached ? Color.green : Color.gray).opacity(0.15), in: Capsule())
            .foregroundStyle(attached ? .green : .secondary)
    }
}

// MARK: - Date helper

private extension Date {
    var relativeString: String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(self)))
        switch seconds {
        case ..<60:      return "\(seconds)s ago"
        case ..<3600:    return "\(seconds / 60)m ago"
        case ..<86400:   return "\(seconds / 3600)h ago"
        default:         return "\(seconds / 86400)d ago"
        }
    }
}
