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
                .onAppear {
                    store.refresh()
                    updates.checkIfDue()
                }
        }
        // The window fits its content: each screen has a very different natural
        // height, and a fixed size left the short ones mostly empty.
        .windowResizability(.contentSize)

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
                .popoverChrome()
                // Opening the popover is the moment the user is looking, so re-probe
                // then. Relying only on mount notifications leaves the panel showing
                // whatever it last saw if one is ever missed.
                .onAppear {
                    store.refresh()
                    updates.checkIfDue()
                }
        } label: {
            MenuBarLabel(screen: store.screen,
                         mounted: store.snapshot != nil,
                         hasWarnings: (store.snapshot?.warningCount ?? 0) > 0)
        }
        .menuBarExtraStyle(.window)
    }
}
