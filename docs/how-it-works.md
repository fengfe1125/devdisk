# How DevDisk works

**English** · [简体中文](how-it-works.zh-CN.md)

This page covers the details behind the [README](../README.md): the exact eject steps, what DevDisk can and can't detect, and how to test it.

A version number in this repository doesn't mean that version has been released. See [GitHub Releases](https://github.com/fengfe1125/devdisk/releases) for published versions.

## Before ejecting: a read-only check

Clicking **Safe Eject** first runs a read-only check. If nothing needs handling, DevDisk simply tries a normal system eject. If it needs to quit apps, stop specific background services, or detach read-only disk images, it shows you the impact first and waits for you to confirm.

- A matching process name or command line only counts as "possibly related". That's never enough to quit an app.
- Acting on a process requires evidence that it holds files on the target volume, plus a check of its PID, user, start time, and executable.
- Timeouts, failures, and incomplete checks are shown as such. An unknown result is never shown as normal or as "nobody is using it".
- Switching drives, re-checking, or a change in what's mounted invalidates the old task; old results can't overwrite a new drive.
- **Stop** halts the remaining steps. Quit or stop requests that were already sent can't be undone.
- Once the final system eject has been submitted, it can no longer be stopped; DevDisk waits for the result and verifies it. It never says the drive is safe to unplug without a verified success.

## What happens when you eject

| Check result | What DevDisk does |
|---|---|
| Nothing to prepare | Tries a normal `diskutil eject` and lets macOS decide |
| Something it can handle | Shows the target drive, what it will act on, the file evidence, and the impact; acts after you confirm |
| Incomplete check | Re-check, cancel, or explicitly choose "Only try a system eject" |
| Simulators, foreground builds, unknown processes, writable or unknown disk images | Asks you to deal with them first, then re-check |
| Several mounted volumes on the same physical drive | Lists the related volumes; only allows a normal system eject after explicit confirmation, without closing any processes |
| The target changed, isn't an external physical drive, or its layout can't be confirmed | Stops and hands it back to you |

"Only try a system eject" doesn't quit apps, stop services, or detach images, and never uses force. When a check is incomplete, DevDisk doesn't claim nobody is using the drive.

After you confirm, the order is: confirm the target and scope → ask GUI apps to quit → stop the specific services → detach read-only images → re-check → system eject → verify the drive is offline.

### What DevDisk may handle for you

- **GUI apps**: must map to an actual running instance owned by the current user. DevDisk asks that instance to quit with `NSRunningApplication.terminate()`. The app handles its own save dialogs; if it refuses or keeps running, DevDisk stops and never escalates to a force quit.
- **Specific services**: the current user's Gradle daemon, Kotlin daemon, and adb server receive SIGTERM only when there's real file-holding evidence and you've confirmed. Sending the signal doesn't mean the process exited; DevDisk waits for it to end.
- **Handle yourself**: simulators, Gradle builds running in the foreground, unknown processes, and anything that can't be identified reliably never receive a termination signal. The specific services may also still be busy, and the preview reminds you of that.
- **System and other users' processes**: never touched. Inferred entries are shown separately from what the scan actually found.
- **Disk images**: read-only images are detached normally after you confirm; writable images, or images whose read/write mode is unknown, are never detached automatically.

A preview older than 30 seconds, or a change in the target's mount state, needs a new check. Confirming doesn't cover anything new: if new holders or images show up, DevDisk returns an updated preview and keeps the count of what it has already done.

## What DevDisk can and can't detect

With normal permissions, DevDisk can only check the file handles visible to you. Even a complete scan doesn't mean it saw every user and system service. `lsof +D` can still time out because of a large volume, permissions, or file system problems; the limit is 30 seconds. An incomplete result can help explain a problem, but is never treated as complete enough to act on automatically.

Hardware information is aimed mainly at APFS/NVMe development drives; other file systems and enclosures may only report part of it. APFS setups spanning several physical drives, complex storage layouts, and startup disks never enter the automatic cleanup flow.

Configuration checks distinguish between OK, problem, unknown, and not applicable:

- Time Machine: only checks whether the whole volume is excluded. It doesn't prove your backup setup works, that backups succeed, or that every folder is included.
- Spotlight "indexing enabled" is a setting; it doesn't mean indexing is happening right now.
- Disk sleep shows the system setting; the actual behavior depends on the hardware.
- Volume ownership shows as not applicable on ExFAT; missing properties show as unknown.
- The leftover mount point check ignores volumes that are currently mounted.

Configuration fixes are still copyable commands; the app never runs sudo. SMART data and capacity show the current state; health history and trend alerts aren't part of this version.

## Switching drives, default drive, and refreshing

Click the drive name in the header to switch drives. "Set as default" saves the volume UUID when there is one, so it keeps working after the drive is renamed. The older `targetMountPoint` setting migrates the first time it matches a real external volume and keeps waiting while the drive is offline; explicitly changing the path in settings removes the old UUID binding. Trailing spaces in paths are kept as-is.

A volume without a UUID is only identified by its device identity for the current mount session. A leftover folder existing doesn't mean the drive is mounted.

Opening the panel only does a light refresh. Folder statistics load only when capacity and "used space breakdown" are expanded; successful results are cached for 5 minutes, and clicking refresh clears the cache. Before ejecting, DevDisk cancels its own scans and waits for them to end, so it never ends up holding the drive itself.

The menu bar popover and the standalone window share one state. Switching windows never starts a second eject; the target drive is locked during the check, confirmation, and eject.

## Settings and updates

Capacity, hardware health, configuration checks, usage, and volume information can each be turned on or off. Hardware health has three levels: basic, standard, and all. The gear button in the panel and the settings window opened with `⌘,` share the same display settings.

The app checks GitHub Releases at most once a day and only shows a download link; it never replaces itself. You can turn the check off in settings.

## Code structure

- `ProbeResult<Value>`: stores the collection status, time, data, and the reason for any problem.
- `VolumeIdentity` and the system mount table: keep the volume's identity, its current mount path, and its temporary device identity apart.
- `DiskStore`: separate page and operation state; a generation counter and cancellation tokens stop stale results from being written back, and repeated refreshes are merged.
- `EjectPlan` / `EjectFlow`: the read-only check defines what you confirm; everything is verified again before running, and cancellation and identity are checked before every side effect.
- `CommandRunner`: command results can be injected; the real runner reads pipes with bounded non-blocking reads, a hard timeout, and cancellation, so no pipe-reading threads are left behind.

GUI apps and services are never force-killed. The runner's timeout cleanup only applies to probe and command child processes that DevDisk started itself.

## Testing and debugging

Default tests use simulated disks, processes, and command results, and never eject a real device. They cover parsing, the impact preview, PID reuse, cancellation, races when switching drives, command cleanup, multiple volumes, and unknown results.

```bash
swift test
./package.sh -
build/DevDisk.app/Contents/MacOS/DevDisk --selftest
.build/debug/DevDisk --snapshot-demo /tmp/devdisk-snapshots
```

`--snapshot-demo` uses clearly labeled demo data to render light and dark snapshots of the short and long previews, the unknown result, the running state, and the state waiting for the system. The real popover's anchoring, scrolling, and pinned action area still need checking in the running app; snapshots can't replace that.

Two extra integration tests must be enabled explicitly:

```bash
# Read-only check of the given external drive's layout; no file scan, no eject
DEVDISK_READONLY_TARGET='/Volumes/YourDevDrive' swift test \
  --filter TargetTopologyTests.testReadOnlyRealTargetWhenExplicitlyConfigured

# Creates a uniquely named temporary disk image and uses a controlled tail process
# to verify that eject is refused while the file is in use and succeeds afterwards
DEVDISK_SCRATCH_TEST=1 swift test --filter ScratchDiskTests
```

This command performs a real eject. Only use it on a drive you're about to unplug:

```bash
.build/debug/DevDisk --eject '/Volumes/YourDevDrive'
```

The CLI and the app use the same checks and rules. If anything will be affected, you must confirm in an interactive terminal; in a non-interactive environment it exits with a non-zero status instead of skipping confirmation. If there's nothing to prepare, it can still try a normal system eject directly.

Other entry points: `--snapshot <output dir> [mount point]` renders with real probes; `--check-update [version]` checks the real GitHub API.

The validation record for this version: [1.1.0 validation record](validation-1.1.0.md) (in Chinese).
