import Combine
import SwiftUI

#if os(macOS)
import ServiceManagement
#endif

/// Keeps the macOS host available to run subscription checks without exposing
/// ServiceManagement APIs to the iOS controller build.
@MainActor
final class MacLoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var statusDescription = ""
    @Published private(set) var lastErrorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
#if os(macOS)
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        statusDescription = description(for: status)
#else
        isEnabled = false
        statusDescription = "Available on Mac"
#endif
    }

    func setEnabled(_ enabled: Bool) async {
        lastErrorMessage = nil

        do {
            try Self.setEnabled(enabled)
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        refresh()
    }

    static func setEnabled(_ enabled: Bool) throws {
#if os(macOS)
        let service = SMAppService.mainApp

        if enabled {
            if service.status == .notRegistered {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
#endif
    }

#if os(macOS)
    private func description(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            "Off"
        case .enabled:
            "On"
        case .requiresApproval:
            "Approval required in System Settings"
        case .notFound:
            "Unavailable"
        @unknown default:
            "Unavailable"
        }
    }
#endif
}
