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
                if plan.target.multipleVolumes || plan.forceConfirmation {
                    PanelSection(title: L("ejectpreviewview.ejecting.the.disk.affects.these.volumes")) {
                        ForEach(plan.target.affected, id: \.device) { volume in
                            Text("\(volume.name) · \(volume.mount)").font(.caption)
                        }
                        if !plan.forceConfirmation {
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
                if !plan.forceConfirmation {
                    group(L("ejectpreviewview.apps.to.request.to.quit"), plan.apps, note: L("ejectpreviewview.quitting.affects.the.entire.app.each.app.handles"))
                    group(L("ejectpreviewview.approved.background.services.to.stop"), plan.daemons, note: L("ejectpreviewview.services.may.still.be.working.after.confirmation.sends"))
                    if !plan.manual.isEmpty {
                        PanelSection(title: L("ejectpreviewview.other.tasks")) {
                            Text(L("ejectpreviewview.terminate.warning")).font(.caption).foregroundStyle(.orange)
                            ForEach(plan.manual) { holder in
                                HolderRow(holder: holder)
                                if holder.canTerminateTask, let identity = holder.identity {
                                    Toggle(L("ejectpreviewview.allow.terminate", holder.displayName), isOn: Binding(
                                        get: { store.ejectPlan?.selectedTasks.contains(identity) == true },
                                        set: { store.selectTask(identity, selected: $0) }
                                    )).toggleStyle(.checkbox).font(.caption)
                                } else {
                                    Text(L("ejectpreviewview.save.and.stop.these.tasks.then.scan.again"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
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
                if plan.forceConfirmation {
                    PrimaryButton(title: L("ejectforce.confirm"), symbol: "exclamationmark.triangle") { store.confirmEject(mode: .force) }
                        .disabled(!plan.canForce)
                } else {
                    if plan.canPrepare {
                        PrimaryButton(title: L(plan.needsContinuation ? "ejectpreviewview.continue.checking" : "ejectpreviewview.confirm.and.eject"), symbol: "eject.fill") { store.confirmEject() }
                    }
                    if plan.canSystemOnly {
                        PrimaryButton(title: L("ejectpreviewview.try.system.eject.only"), symbol: "eject") { store.confirmEject(mode: .systemOnly) }
                        Text(L("ejectpreviewview.does.not.quit.apps.stop.services.eject.images"))
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if store.canOfferForce {
                        Button(L("ejectforce.action")) { store.requestForceEject() }.buttonStyle(.bordered)
                    }
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
