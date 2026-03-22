import SwiftUI

@main
struct MiniWatcherApp: App {
    @StateObject private var metricsService = MetricsService()

    var body: some Scene {
        WindowGroup {
            TabView {
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }

                HistoryView()
                    .tabItem {
                        Label("History", systemImage: "chart.line.uptrend.xyaxis")
                    }

                ServicesView()
                    .tabItem {
                        Label("Services", systemImage: "list.bullet.rectangle")
                    }

                DockerView()
                    .tabItem {
                        Label("Docker", systemImage: "shippingbox")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .environmentObject(metricsService)
        }
    }
}
