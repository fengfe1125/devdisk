import SwiftUI

struct EjectPreviewView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore
    var body: some View {
        if let plan = store.ejectPlan {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: L(plan.forceConfirmation ? "ejectforce.confirm.title" : "ejectpreviewview.eject.preview"), aside: plan.incomplete ? L("ejectpreviewview.scan.incomplete") : L("ejectpreviewview.read.only.preflight.complete")) {
                    Text(plan.target.volume.name).font(.headline)
                    Text(plan.target.volume.mount).font(.caption).textSelection(.enabled)
                    Text(L("ejectpreviewview.scanned.must.recheck.after.seconds", plan.createdAt.formatted(.dateTime.hour().minute().second().locale(language.resolved.locale))))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("ejectpreviewview.standard.permissions.reveal.only.visible.handles.macos.checks"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if plan.forceConfirmation {
                    Text(L("ejectforce.risk")).font(.callout).foregroundStyle(.orange).padding(UI.hPad)
                    Text(L("ejectforce.no.process.kill")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, UI.hPad)
                }
                if let action = plan.forceProcessConfirmation {
                    Text(L(action == .closeOnly ? "forceprocess.risk.close" : plan.selectedForceProcesses.isEmpty ? "forceprocess.risk.disk.only" : "forceprocess.risk.joint"))
                        .font(.callout).foregroundStyle(.orange).padding(UI.hPad)
                }
                if !plan.forceRequested.isEmpty {
                    Text(L("forceprocess.requests", plan.forceRequested.count))
                        .font(.caption).foregroundStyle(.orange).padding(UI.hPad)
                }
                if plan.completedApps + plan.completedDaemons + plan.completedImages > 0 {
                    Text(L("ejectpreviewview.so.far.apps.quit.services.stopped.images.ejected", plan.completedApps, plan.completedDaemons, plan.completedImages))
                        .font(.caption).foregroundStyle(.secondary).padding(UI.hPad)
                }
                if let notice = plan.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange).padding(UI.hPad)
                }
                if let failure = plan.failure {
                    EjectFailureDetails(failure: failure).padding(.horizontal, UI.hPad)
                }
                if plan.target.multipleVolumes || plan.forceConfirmation || plan.forceProcessConfirmation == .closeAndEject {
                    PanelSection(title: L("ejectpreviewview.ejecting.the.disk.affects.these.volumes")) {
                        Text(M("ejectfailure.disk", plan.target.physicalDisk))
                            .font(.caption).textSelection(.enabled)
                        ForEach(plan.target.affected, id: \.device) { volume in
                            Text("\(volume.name) · \(volume.mount)").font(.caption)
                        }
                        if !plan.forceConfirmation && plan.forceProcessConfirmation == nil {
                            Text(L("ejectpreviewview.this.version.does.not.automatically.handle.processes.on"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !plan.issues.isEmpty {
                    PanelSection(title: L("ejectpreviewview.scan.incomplete")) {
                        ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !plan.simulators.isEmpty {
                    PanelSection(title: L("ejectpreviewview.related.simulators")) {
                        Text(L("ejectpreviewview.simulators.will.shutdown.normally"))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.simulators) { device in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.system(size: 12, weight: .medium))
                                Text("\(device.displayRuntime) · \(device.state)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !plan.forceConfirmation {
                    PanelSection(title: L("forceprocess.occupants")) {
                        Text(L("forceprocess.selection.count", plan.selectedForceProcesses.count, plan.forceEligible.count))
                            .font(.caption)
                        if plan.forceProcessConfirmation == nil {
                            HStack {
                                Button(L("forceprocess.select.all")) { store.selectAllForceProcesses(true) }
                                    .disabled(plan.forceEligible.isEmpty)
                                Button(L("forceprocess.deselect.all")) { store.selectAllForceProcesses(false) }
                                    .disabled(plan.selectedForceProcesses.isEmpty)
                            }.buttonStyle(.bordered)
                            Text(L("forceprocess.normal.note")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(plan.holders) { holder in
                            HolderRow(holder: holder)
                            if let identity = holder.identity, plan.forceEligible.contains(identity) {
                                Text("PID \(identity.pid) · \(identity.executable)")
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                if plan.forceProcessConfirmation != nil {
                                    Text(L(plan.selectedForceProcesses.contains(identity)
                                           ? "forceprocess.selected" : "forceprocess.unselected"))
                                        .font(.caption).foregroundStyle(.orange)
                                } else {
                                    Toggle(L("forceprocess.select", holder.displayName), isOn: Binding(
                                        get: { store.ejectPlan?.selectedForceProcesses.contains(identity) == true },
                                        set: { store.selectForceProcess(identity, selected: $0) }
                                    )).toggleStyle(.checkbox).font(.caption)
                                    if holder.canTerminateTask {
                                        Toggle(L("ejectpreviewview.allow.terminate", holder.displayName), isOn: Binding(
                                            get: { store.ejectPlan?.selectedTasks.contains(identity) == true },
                                            set: { store.selectTask(identity, selected: $0) }
                                        )).toggleStyle(.checkbox).font(.caption)
                                    }
                                }
                            } else {
                                Text(L("forceprocess.ineligible")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if plan.target.multipleVolumes || !plan.simulators.isEmpty {
                            Text(L("forceprocess.scope.blocked")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if !plan.images.isEmpty {
                    PanelSection(title: L("ejectpreviewview.related.disk.images")) {
                        ForEach(Array(plan.images.enumerated()), id: \.offset) { _, image in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(image.name).font(.system(size: 12, weight: .medium))
                                Text(image.path).font(.caption).textSelection(.enabled)
                                ForEach(image.mountPoints, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                if image.mountPoints.isEmpty { Text(L("ejectimage.unmounted.attached")).font(.caption).foregroundStyle(.secondary) }
                                Text(L(!image.accessKnown ? "ejectimage.unknown" : image.writable ? "ejectimage.writable" : "ejectimage.readonly"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

            }
        }
    }
    @ViewBuilder private func group(_ title: String, _ holders: [Holder], note: String) -> some View {
        if !holders.isEmpty {
            PanelSection(title: title) {
                Text(note).font(.caption).foregroundStyle(.secondary)
                ForEach(holders) { HolderRow(holder: $0) }
            }
        }
    }
}

struct EjectPreviewFooter: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore
    var body: some View {
        VStack(spacing: 8) {
            if let plan = store.ejectPlan {
                if let action = plan.forceProcessConfirmation {
                    PrimaryButton(title: L(action == .closeOnly ? "forceprocess.confirm.close" : plan.selectedForceProcesses.isEmpty ? "forceprocess.confirm.disk.only" : "forceprocess.confirm.joint"),
                                  symbol: "exclamationmark.triangle") { store.confirmEject(mode: .forceProcesses) }
                        .disabled(!plan.canForceProcesses || (action == .closeOnly && !plan.canCloseSelected))
                    Button(L("forceprocess.back")) { store.cancelForceProcessConfirmation() }.buttonStyle(.bordered)
                } else if plan.forceConfirmation {
                    PrimaryButton(title: L("ejectforce.confirm"), symbol: "exclamationmark.triangle") { store.confirmEject(mode: .force) }
                        .disabled(!plan.canForce)
                } else {
                    if plan.canPrepare {
                        let title = plan.needsContinuation ? "ejectpreviewview.continue.checking"
                            : (plan.simulators.isEmpty ? "ejectpreviewview.confirm.and.eject" : "ejectpreviewview.shutdown.simulators.and.eject")
                        PrimaryButton(title: L(title), symbol: "eject.fill") { store.confirmEject() }
                    }
                    if plan.canSystemOnly {
                        PrimaryButton(title: L("ejectpreviewview.try.system.eject.only"), symbol: "eject") { store.confirmEject(mode: .systemOnly) }
                        Text(L("ejectpreviewview.does.not.quit.apps.stop.services.eject.images"))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button(L("forceprocess.close.selected")) { store.requestForceProcesses(.closeOnly) }
                        .buttonStyle(.bordered).disabled(!plan.canCloseSelected)
                    Button(L(plan.selectedForceProcesses.isEmpty ? "ejectforce.action" : "forceprocess.close.and.eject")) { store.requestForceProcesses(.closeAndEject) }
                        .buttonStyle(.bordered).disabled(!plan.canForceProcesses)
                    if store.canOfferForce && !plan.canForceProcesses {
                        Button(L("ejectforce.action")) { store.requestForceEject() }.buttonStyle(.bordered)
                    }
                }
                if !plan.canSystemOnly {
                    Text(L("ejectpreviewview.simulator.check.must.complete"))
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                HStack {
                    Button(L("ejectpreviewview.scan.again")) { store.retryPreflight() }
                    Spacer()
                    Button(L("ejectpreviewview.cancel")) { store.cancelEject() }
                }.buttonStyle(.bordered)
            }
        }.padding(.horizontal, UI.hPad).padding(.vertical, 11)
    }
}

struct EjectFailureDetails: View {
    let failure: EjectFailure
    var title: String = L("ejectpreviewview.failure.details")
    @EnvironmentObject var store: DiskStore
    @ObservedObject private var language = LanguageStore.shared
    var body: some View {
        DisclosureGroup(title) {
            Text(failure.report).font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(L("ejectpreviewview.copy.failure")) { store.copy(failure.report) }
                .buttonStyle(.bordered)
        }.font(.caption)
    }
}
