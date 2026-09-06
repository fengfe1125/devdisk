import Foundation

// MARK: - Volume

struct VolumeInfo {
    var name: String
    var mountPoint: String
    var filesystem: String
    var isEncrypted: Bool
    var isExternal: Bool
    var ownersEnabled: Bool
    var volumeUUID: String
    var deviceIdentifier: String      // disk7s1
    var containerReference: String?   // disk7
    /// Physical whole-disk BSD name (disk6) — resolved through the APFS physical
    /// store, never from ParentWholeDisk, which names the synthesized container.
    var physicalDisk: String?

    var totalBytes: Int64
    var freeBytes: Int64
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

// MARK: - Hardware & health

struct DriveHardware {
    var model: String?
    var serial: String?
    var firmware: String?
    var trimSupported: Bool?
    var smartStatus: String?     // "Verified"
    var linkWidth: String?       // "x4"
    var linkSpeed: String?       // "16.0 GT/s"

    /// "PCIe 4.0 ×4 · 16.0 GT/s" — PCIe generation is derived from the link rate.
    var linkDescription: String? {
        guard let w = linkWidth, let s = linkSpeed else { return nil }
        let lanes = w.replacingOccurrences(of: "x", with: "×")
        let gen: String? = {
            guard let gts = Double(s.split(separator: " ").first.map(String.init) ?? "") else { return nil }
            switch gts {
            case 30...:      return "PCIe 5.0"
            case 15..<30:    return "PCIe 4.0"
            case 7..<15:     return "PCIe 3.0"
            case 4..<7:      return "PCIe 2.0"
            default:         return nil
            }
        }()
        return [gen, lanes].compactMap { $0 }.joined(separator: " ") + " · " + s
    }
}

struct SmartHealth {
    var temperatureC: Int?
    var temperatureSensors: [Int]
    var percentageUsed: Int?        // 0-100, NVMe wear indicator
    var availableSpare: Int?
    var dataUnitsWritten: Int64?
    var dataUnitsRead: Int64?
    var powerOnHours: Int?
    var powerCycles: Int?
    var unsafeShutdowns: Int?
    var mediaErrors: Int?
    var criticalWarning: Int?
    var passed: Bool?

    /// An NVMe data unit is 1000 × 512 bytes.
    static let bytesPerDataUnit: Int64 = 512_000

    var bytesWritten: Int64? { dataUnitsWritten.map { $0 * Self.bytesPerDataUnit } }
    var bytesRead: Int64?    { dataUnitsRead.map { $0 * Self.bytesPerDataUnit } }
    var lifeRemaining: Int?  { percentageUsed.map { max(0, 100 - $0) } }

    /// Every power-off so far has been unclean. Enclosures that cut power without a
    /// clean shutdown notification inflate this, so it is reported, not diagnosed.
    var allShutdownsUnsafe: Bool {
        guard let u = unsafeShutdowns, let c = powerCycles, c > 0 else { return false }
        return u >= c
    }
}

// MARK: - Configuration checks

enum CheckSeverity {
    case ok, warning, critical
}

struct ConfigCheck: Identifiable {
    let id: String
    var severity: CheckSeverity
    var title: String
    var detail: String
    /// Shell command that fixes it, offered as copyable text — the app never runs sudo itself.
    var fixCommand: String?
    /// Opens a System Settings pane instead of copying a command.
    var settingsURL: String?
}

// MARK: - Occupancy

enum HolderKind {
    case guiApp        // asked to quit via AppleScript, never killed
    case daemon        // safe to terminate; restarts on demand
    case system        // not ours to touch; released by diskutil eject
}

/// How we learned about a holder. System daemons cannot be enumerated without root,
/// so they are inferred from volume state rather than scanned — the UI says which.
enum HolderEvidence {
    case scanned(openFiles: Int, sampleFiles: [String])
    case inferred(reason: String)
}

struct Holder: Identifiable {
    var id: String { pids.map(String.init).joined(separator: ",") + name }
    var name: String
    var pids: [Int32]
    var user: String
    var kind: HolderKind
    var evidence: HolderEvidence
    /// Bundle identifier, present for GUI apps so AppleScript can address them.
    var bundleID: String?

    var openFileCount: Int? {
        if case .scanned(let n, _) = evidence { return n }
        return nil
    }
    var sampleFiles: [String] {
        if case .scanned(_, let f) = evidence { return f }
        return []
    }
    var inferenceReason: String? {
        if case .inferred(let r) = evidence { return r }
        return nil
    }
}

struct OccupancyReport {
    var holders: [Holder]
    var scanDepth: ScanDepth
    var scannedAt: Date
    var duration: TimeInterval
    /// Open files found that belong to this user's processes — not the number of
    /// files walked. An unprivileged lsof can legitimately report zero on a busy
    /// volume, which is exactly why system holders are inferred separately.
    var openFilesFound: Int?

    enum ScanDepth {
        case quick    // pgrep against a known list
        case full     // lsof +D over the volume
        case elevated // lsof as root via one-shot authorization

        var label: String {
            switch self {
            case .quick:    return "快速检测"
            case .full:     return "完整检测"
            case .elevated: return "管理员检测"
            }
        }
    }

    func holders(_ kind: HolderKind) -> [Holder] { holders.filter { $0.kind == kind } }
    var mine: [Holder] { holders.filter { $0.kind != .system } }
}

// MARK: - Directory usage

struct DirectoryUsage: Identifiable {
    var id: String { name }
    var name: String
    var bytes: Int64
}

// MARK: - Aggregate

struct DiskSnapshot {
    var volume: VolumeInfo
    var hardware: DriveHardware
    var health: SmartHealth?
    var healthUnavailableReason: String?
    var checks: [ConfigCheck]
    var directories: [DirectoryUsage]
    var occupancy: OccupancyReport?

    var warningCount: Int {
        checks.filter { $0.severity != .ok }.count
    }
}

// MARK: - Formatting

enum Fmt {
    /// Decimal units, matching what Finder and diskutil report.
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = b >= 1_000_000_000 ? [.useGB] : [.useMB, .useKB]
        return f.string(fromByteCount: b)
    }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func hours(_ h: Int) -> String {
        h < 48 ? "\(h) 小时" : "\(h) 小时（约 \(h / 24) 天）"
    }
}
