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
        case .basic:    return "基础"
        case .standard: return "标准"
        case .full:     return "全部"
        }
    }

    var caption: String {
        switch self {
        case .basic:    return "接口、SMART、TRIM"
        case .standard: return "再加写入量、寿命、通电时间、温度"
        case .full:     return "再加读取量、备用块、通电次数、非正常断电、介质错误"
        }
    }
}
