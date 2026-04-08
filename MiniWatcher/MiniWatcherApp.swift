import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, home, history, services, docker, tmux

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .home: "Home"
        case .history: "History"
        case .services: "Services"
        case .docker: "Docker"
        case .tmux: "Tmux"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.bottom.50percent"
        case .home: "house.fill"
        case .history: "chart.line.uptrend.xyaxis"
        case .services: "list.bullet.rectangle"
        case .docker: "shippingbox"
        case .tmux: "terminal"
        }
    }
}

@MainActor
class TabSettings: ObservableObject {
    @Published var enabledTabs: [AppTab] {
        didSet { save() }
    }

    private let key = "enabledTabs"

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "enabledTabs"),
           !saved.isEmpty {
            enabledTabs = saved.compactMap { AppTab(rawValue: $0) }
        } else {
            enabledTabs = AppTab.allCases
        }
    }

    func save() {
        UserDefaults.standard.set(enabledTabs.map(\.rawValue), forKey: key)
    }

    func isEnabled(_ tab: AppTab) -> Bool {
        enabledTabs.contains(tab)
    }

    func toggle(_ tab: AppTab) {
        if let index = enabledTabs.firstIndex(of: tab) {
            if enabledTabs.count > 1 {
                enabledTabs.remove(at: index)
            }
        } else {
            enabledTabs.append(tab)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        enabledTabs.move(fromOffsets: source, toOffset: destination)
    }
}

@main
struct MiniWatcherApp: App {
    @StateObject private var metricsService = MetricsService()
    @StateObject private var haService = HomeAssistantService()
    @StateObject private var tabSettings = TabSettings()

    var body: some Scene {
        WindowGroup {
            TabView {
                ForEach(tabSettings.enabledTabs) { tab in
                    Tab(tab.label, systemImage: tab.icon) {
                        switch tab {
                        case .dashboard: DashboardView()
                        case .home: HomeView()
                        case .history: HistoryView()
                        case .services: ServicesView()
                        case .docker: DockerView()
                        case .tmux: TmuxView()
                        }
                    }
                }

                Tab("Settings", systemImage: "gear") {
                    SettingsView()
                }
            }
            .environmentObject(metricsService)
            .environmentObject(haService)
            .environmentObject(tabSettings)
        }
    }
}
