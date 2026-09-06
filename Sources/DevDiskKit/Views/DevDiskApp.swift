import SwiftUI

public struct DevDiskApp: App {
    @StateObject private var store = DiskStore()
    @StateObject private var updates = UpdateChecker()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
                .environmentObject(updates)
                .frame(width: 380)
                .onAppear { updates.checkIfDue() }
        } label: {
            MenuBarLabel(screen: store.screen,
                         hasWarnings: (store.snapshot?.warningCount ?? 0) > 0)
        }
        .menuBarExtraStyle(.window)
    }
}
