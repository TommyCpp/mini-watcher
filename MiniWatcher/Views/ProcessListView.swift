import SwiftUI

enum ProcessSortOrder: String, CaseIterable {
    case cpu = "CPU"
    case memory = "MEM"
}

struct ProcessListView: View {
    let processes: [ProcessInfo]
    @Binding var sortOrder: ProcessSortOrder
    @State private var searchText = ""

    private var sortedProcesses: [ProcessInfo] {
        let filtered = searchText.isEmpty
            ? processes
            : processes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        switch sortOrder {
        case .cpu:
            return filtered.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory:
            return filtered.sorted { $0.memoryMb > $1.memoryMb }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                TextField("Search processes", text: $searchText)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.top, 8)

            // Header with sort toggle
            HStack {
                Text("Process")
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button { sortOrder = .cpu } label: {
                    HStack(spacing: 2) {
                        Text("CPU")
                        if sortOrder == .cpu {
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                }
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(sortOrder == .cpu ? .primary : .secondary)

                Button { sortOrder = .memory } label: {
                    HStack(spacing: 2) {
                        Text("MEM")
                        if sortOrder == .memory {
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                }
                .frame(width: 65, alignment: .trailing)
                .foregroundStyle(sortOrder == .memory ? .primary : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Rows
            ForEach(sortedProcesses) { process in
                HStack {
                    Text(process.name)
                        .font(.subheadline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(String(format: "%.1f%%", process.cpuPercent))
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                        .foregroundStyle(process.cpuPercent > 50 ? .red : .primary)

                    Text(String(format: "%.0fM", process.memoryMb))
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 65, alignment: .trailing)
                        .foregroundStyle(process.memoryMb > 500 ? .orange : .primary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                if process.id != sortedProcesses.last?.id {
                    Divider().padding(.leading)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1))
    }
}
