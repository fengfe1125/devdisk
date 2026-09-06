import SwiftUI

public struct DevDiskApp: App {
    @StateObject private var store = DiskStore()
    @StateObject private var updates = UpdateChecker()

    public init() {
        PanelSetting.registerDefaults()
    }

    public var body: some Scene {
        // A Dock icon with nothing behind it would be dead weight — clicking it has to
        // open something. This window carries the same panel, resizable, so the body
        // is not squeezed into a popover-sized card.
        Window("DevDisk", id: DiskStore.mainWindowID) {
            PanelView(presentation: .window)
                .environmentObject(store)
                .environmentObject(updates)
                .onAppear { updates.checkIfDue() }
        }
        .defaultSize(width: 400, height: 700)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updates)
        }

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
