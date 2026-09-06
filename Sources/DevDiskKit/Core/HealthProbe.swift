import Foundation

/// Reads the NVMe SMART log via smartctl. Verified on this machine: no root required
/// (`smartctl -a -j /dev/disk6` exits 0 as a normal user), so there is no privilege
/// escalation path here. When smartmontools is absent or the enclosure firmware does
/// not tunnel the SMART log, the caller degrades to the coarse status from
/// system_profiler instead of showing blanks.
struct HealthProbe {
    let runner: CommandRunner

    init(runner: CommandRunner = SystemCommandRunner()) {
        self.runner = runner
    }

    enum Unavailable: Error, LocalizedError {
        case notInstalled
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "未安装 smartmontools（brew install smartmontools）"
            case .unsupported(let why):
                return why.isEmpty ? "该硬盘盒不透传 SMART 日志" : why
            }
        }
    }

    func health(physicalDisk: String?) throws -> SmartHealth {
        guard let smartctl = Tool.smartctl else { throw Unavailable.notInstalled }
        guard let disk = physicalDisk else { throw Unavailable.unsupported("") }

        let r = try runner.run(smartctl, ["-a", "-j", "/dev/" + disk])
        // smartctl uses a bitmask exit status; bits 0-2 mean the device could not be
        // opened or the command failed. Higher bits are health warnings and still
        // come with a valid payload, so they are not treated as failures here.
        if r.exitCode & 0b111 != 0 {
            throw Unavailable.unsupported(Self.failureReason(r) ?? "")
        }
        guard let h = Self.parse(r.stdout) else {
            throw Unavailable.unsupported("smartctl 输出无法解析")
        }
        return h
    }

    static func failureReason(_ r: CommandResult) -> String? {
        if let d = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
           let msgs = d["smartctl"] as? [String: Any],
           let list = msgs["messages"] as? [[String: Any]],
           let first = list.compactMap({ $0["string"] as? String }).first {
            return first
        }
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? nil : err
    }

    static func parse(_ data: Data) -> SmartHealth? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let log = d["nvme_smart_health_information_log"] as? [String: Any] ?? [:]
        func int(_ k: String) -> Int? { log[k] as? Int }

        let temp = (d["temperature"] as? [String: Any])?["current"] as? Int
            ?? int("temperature")
        let hours = (d["power_on_time"] as? [String: Any])?["hours"] as? Int
            ?? int("power_on_hours")
        let passed = (d["smart_status"] as? [String: Any])?["passed"] as? Bool

        // An empty health log means the device answered but exposed no SMART data.
        if log.isEmpty && temp == nil && passed == nil { return nil }

        return SmartHealth(
            temperatureC: temp,
            temperatureSensors: log["temperature_sensors"] as? [Int] ?? [],
            percentageUsed: int("percentage_used"),
            availableSpare: int("available_spare"),
            dataUnitsWritten: (log["data_units_written"] as? NSNumber)?.int64Value,
            dataUnitsRead: (log["data_units_read"] as? NSNumber)?.int64Value,
            powerOnHours: hours,
            powerCycles: int("power_cycles") ?? d["power_cycle_count"] as? Int,
            unsafeShutdowns: int("unsafe_shutdowns"),
            mediaErrors: int("media_errors"),
            criticalWarning: int("critical_warning"),
            passed: passed
        )
    }
}
