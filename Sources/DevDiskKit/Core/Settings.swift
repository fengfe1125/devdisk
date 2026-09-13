import Foundation

/// Keys for what the panel shows. Read through `@AppStorage` in the views rather
/// than an ObservableObject: `@AppStorage` observes UserDefaults directly, so the
/// popover and the settings window stay in sync without any wiring between them.
enum PanelSetting {
    static let capacity        = "show.capacity"
    static let breakdownOpen   = "show.breakdownOpen"
    static let hardware        = "show.hardware"
    static let hardwareDetail  = "show.hardwareDetail"
    static let checks          = "show.checks"
    static let checksAllRows   = "show.checksAllRows"
    static let occupancy       = "show.occupancy"
    static let volume          = "show.volume"
    static let version         = "show.version"

    /// Defaults are registered once at launch so every `@AppStorage` read agrees
    /// with the settings window even before the user has touched anything.
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            capacity: true,
            breakdownOpen: false,
            hardware: true,
            hardwareDetail: HardwareDetail.standard.rawValue,
            checks: true,
            checksAllRows: false,
            occupancy: true,
            volume: false,
            version: true,
        ])
    }
}

/// How much of the SMART data the hardware section shows.
enum HardwareDetail: String, CaseIterable, Identifiable {
    case basic, standard, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .basic:    return L("settings.basic")
        case .standard: return L("settings.standard")
        case .full:     return L("settings.all")
        }
    }

    var caption: String {
        switch self {
        case .basic:    return L("settings.interface.smart.trim")
        case .standard: return L("settings.also.writes.life.left.power.on.time.and")
        case .full:     return L("settings.also.reads.spare.blocks.power.cycles.unsafe.shutdowns")
        }
    }
}
