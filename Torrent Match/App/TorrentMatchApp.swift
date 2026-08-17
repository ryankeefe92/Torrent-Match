//
//  Torrent_MatchApp.swift
//  Torrent Match
//
//  Created by Ryan Keefe on 5/17/26.
//

import SwiftUI
import SwiftData

@main
struct Torrent_MatchApp: App {
    @StateObject private var transmissionStore = TransmissionStore()
    @StateObject private var tvAutomation = TVAutomationCoordinator()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TVSubscription.self,
            TVAcquisitionPlan.self,
            TVAcquisitionJob.self,
            TVAcquisitionHistoryEntry.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(transmissionStore)
                .environmentObject(tvAutomation)
        }
        .modelContainer(sharedModelContainer)
    }
}
