import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var transmissionStore: TransmissionStore
    @EnvironmentObject private var tvAutomation: TVAutomationCoordinator
#if os(macOS)
    @AppStorage("tv.launchAtLogin") private var launchAtLogin = true
#endif

    var body: some View {
        TabView {
            MovieSearchView()
                .tabItem {
                    Label("Movies", systemImage: "film")
                }

            TVSubscriptionsView()
                .tabItem {
                    Label("Shows", systemImage: "tv")
                }
        }
        .onAppear {
            transmissionStore.startMonitoring()
#if os(macOS)
            tvAutomation.start(
                in: modelContext,
                transmissionStore: transmissionStore
            )
            if launchAtLogin {
                try? MacLoginItemController.setEnabled(true)
            }
#endif
        }
    }
}
