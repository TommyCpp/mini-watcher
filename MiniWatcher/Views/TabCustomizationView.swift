import SwiftUI

struct TabCustomizationView: View {
    @EnvironmentObject var tabSettings: TabSettings

    var body: some View {
        List {
            Section("Visible Tabs") {
                ForEach(tabSettings.enabledTabs) { tab in
                    tabRow(tab: tab, enabled: true)
                }
                .onMove { tabSettings.move(from: $0, to: $1) }
            }

            let hidden = AppTab.allCases.filter { !tabSettings.isEnabled($0) }
            if !hidden.isEmpty {
                Section("Hidden Tabs") {
                    ForEach(hidden) { tab in
                        tabRow(tab: tab, enabled: false)
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Customize Tabs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tabRow(tab: AppTab, enabled: Bool) -> some View {
        HStack {
            Image(systemName: tab.icon)
                .frame(width: 24)
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
            Text(tab.label)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer()
            Button {
                withAnimation { tabSettings.toggle(tab) }
            } label: {
                Image(systemName: enabled ? "minus.circle.fill" : "plus.circle.fill")
                    .foregroundStyle(enabled ? .red : .green)
            }
        }
    }
}
