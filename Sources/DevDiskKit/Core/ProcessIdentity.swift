import AppKit
import Darwin

struct ProcessIdentity: Hashable {
    let pid: Int32
    let uid: UInt32
    let startedSeconds: UInt64
    let startedMicros: UInt64
    let executable: String
    var bundleID: String? = nil
    var appName: String? = nil
}

protocol ProcessInspecting {
    /// nil means known to have exited; failure means the identity cannot be established.
    func identity(_ pid: Int32) throws -> ProcessIdentity?
    func requestQuit(_ identity: ProcessIdentity) throws
}

struct SystemProcessInspector: ProcessInspecting {
    func identity(_ pid: Int32) throws -> ProcessIdentity? {
        guard pid > 0 else { throw ProbeFailure(M("processidentity.invalid.process.id")) }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return nil }
            throw ProbeFailure(M("processidentity.could.not.verify.the.identity.of.pid", String(pid)))
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw ProbeFailure(M("processidentity.could.not.read.the.executable.for.pid", String(pid)))
        }
        let candidate = NSRunningApplication(processIdentifier: pid)
        let app = candidate?.activationPolicy == .prohibited ? nil : candidate
        return ProcessIdentity(pid: pid, uid: info.pbi_uid,
                               startedSeconds: info.pbi_start_tvsec,
                               startedMicros: info.pbi_start_tvusec,
                               executable: String(cString: path),
                               bundleID: app?.bundleIdentifier,
                               appName: app?.localizedName)
    }

    func requestQuit(_ expected: ProcessIdentity) throws {
        guard try identity(expected.pid) == expected else {
            throw ProbeFailure(M("processidentity.application.identity.changed.scan.again"))
        }
        // NSRunningApplication targets this instance, unlike an AppleScript name/bundle target.
        let request = {
            NSRunningApplication(processIdentifier: expected.pid)?.terminate() == true
        }
        let accepted = Thread.isMainThread ? request() : DispatchQueue.main.sync(execute: request)
        guard accepted else { throw ProbeFailure(M("processidentity.the.app.did.not.accept.the.quit.request")) }
    }
}
