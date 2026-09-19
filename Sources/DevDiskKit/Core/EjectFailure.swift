import Foundation

/// Local diagnostic state, retained until dismissed or a new eject is started.
struct EjectFailure: Equatable {
    let target: EjectTarget
    let stage: String
    let message: Message
    let commandOutput: String
    let blockingPID: Int32?
    let completedApps: Int
    let completedProcesses: Int
    var completedImages: Int
    var commandExitCode: Int32? = nil
    var commandTimedOut = false
    var commandCancelled = false
    var verificationDuration: TimeInterval? = nil
    var verification: EjectVerification? = nil

    var forceUsed = false
    var allowsForce = false
    var relatedImages: [DiskImage] = []
    var pendingImage: DiskImage? = nil

    private var stageLabel: String {
        let keys = ["validate": "ejectflow.verify.target.and.scope", "apps": "ejectflow.request.apps.to.quit",
                    "daemons": "ejectflow.stop.approved.background.services", "images": "ejectflow.eject.read.only.disk.images",
                    "recheck": "ejectflow.recheck.open.files", "unmount": "ejectflow.ask.macos.to.eject",
                    "verify": "ejectflow.verify.eject.result", "force-unmount": "ejectforce.unmount.disk",
                    "force-images": "ejectforce.detach.images"]
        return keys[stage].map { L($0) } ?? stage
    }

    var report: String {
        var lines = [message.text, M("ejectfailure.volume", target.volume.name, target.volume.device).text,
         M("ejectfailure.disk", target.physicalDisk).text, M("ejectfailure.stage", stageLabel).text,
         M("ejectfailure.pid", blockingPID.map(String.init) ?? L("ejectfailure.unknown")).text,
         M("ejectflow.apps.quit.service.processes.stopped.images.ejected.requests", completedApps, completedProcesses, completedImages).text]
        if forceUsed { lines.append(L("ejectforce.used")) }
        if let commandExitCode {
            lines.append(M("ejectfailure.command.result", commandExitCode,
                           commandTimedOut ? L("ejectfailure.yes") : L("ejectfailure.no"),
                           commandCancelled ? L("ejectfailure.yes") : L("ejectfailure.no")).text)
        }
        if let verificationDuration {
            lines.append(M("ejectfailure.verification.duration", Message.number(verificationDuration, decimals: 2)).text)
        }
        if let verification { lines.append(M("ejectfailure.last.verification", verification.detail).text) }
        if !commandOutput.isEmpty { lines.append(commandOutput) }
        return lines.joined(separator: "\n")
    }

    static func blockingPID(in text: String) -> Int32? {
        let pattern = #"(?:dissented by PID\s+|Dissenter PID=)(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text), let pid = Int32(text[range]), pid > 0 else { return nil }
        return pid
    }

    static func isTransientBusy(_ text: String) -> Bool {
        let value = text.lowercased()
        guard !["permission", "not permitted", "not authorized", "privilege", "denied"]
            .contains(where: value.contains) else { return false }
        return ["resource busy", "disk is busy", "volume is busy", "kdareturnbusy", "0x0000c010"]
            .contains(where: value.contains)
    }
}
