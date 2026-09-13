import SwiftUI

struct EjectPreviewView: View {
    @ObservedObject private var language = LanguageStore.shared
    @EnvironmentObject var store: DiskStore
    var body: some View {
        if let plan = store.ejectPlan {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection(title: L("ejectpreviewview.eject.preview"), aside: plan.incomplete ? L("ejectpreviewview.scan.incomplete") : L("ejectpreviewview.read.only.preflight.complete")) {
                    Text(plan.target.volume.name).font(.headline)
                    Text(plan.target.volume.mount).font(.caption).textSelection(.enabled)
                    Text(L("ejectpreviewview.scanned.must.recheck.after.seconds", plan.createdAt.formatted(.dateTime.hour().minute().second().locale(language.resolved.locale))))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L("ejectpreviewview.standard.permissions.reveal.only.visible.handles.macos.checks"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if plan.completedApps + plan.completedDaemons + plan.completedImages > 0 {
                    Text(L("ejectpreviewview.so.far.apps.quit.services.stopped.images.ejected", plan.completedApps, plan.completedDaemons, plan.completedImages))
                        .font(.caption).foregroundStyle(.secondary).padding(UI.hPad)
                }
                if plan.target.multipleVolumes {
                    PanelSection(title: L("ejectpreviewview.ejecting.the.disk.affects.these.volumes")) {
                        ForEach(plan.target.affected, id: \.device) { volume in
                            Text("\(volume.name) · \(volume.mount)").font(.caption)
                        }
                        Text(L("ejectpreviewview.this.version.does.not.automatically.handle.processes.on"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if !plan.issues.isEmpty {
                    PanelSection(title: L("ejectpreviewview.scan.incomplete")) {
                        ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                group(L("ejectpreviewview.apps.to.request.to.quit"), plan.apps, note: L("ejectpreviewview.quitting.affects.the.entire.app.each.app.handles"))
                group(L("ejectpreviewview.approved.background.services.to.stop"), plan.daemons, note: L("ejectpreviewview.services.may.still.be.working.after.confirmation.sends"))
                group(L("ejectpreviewview.handle.manually"), plan.manual, note: L("ejectpreviewview.save.and.stop.these.tasks.then.scan.again"))
                if !plan.images.isEmpty {
                    PanelSection(title: L("ejectpreviewview.related.disk.images")) {
                        ForEach(Array(plan.images.enumerated()), id: \.offset) { _, image in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(image.name).font(.system(size: 12, weight: .medium))
                                Text(image.path).font(.caption).textSelection(.enabled)
                                Text(image.writable || !image.accessKnown ? L("ejectpreviewview.writable.or.unknown.eject.manually") : L("ejectpreviewview.read.only.normal.eject.after.confirmation"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !plan.writableImages.isEmpty {
                    Text(L("ejectpreviewview.manually.eject.writable.images.or.images.with.unknown"))
                        .font(.caption).foregroundStyle(.orange).padding(UI.hPad)
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
                if plan.canPrepare {
                    PrimaryButton(title: L("ejectpreviewview.confirm.and.eject"), symbol: "eject.fill") { store.confirmEject() }
                }
                if plan.canSystemOnly {
                    PrimaryButton(title: L("ejectpreviewview.try.system.eject.only"), symbol: "eject") { store.confirmEject(systemOnly: true) }
                    Text(L("ejectpreviewview.does.not.quit.apps.stop.services.eject.images"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
