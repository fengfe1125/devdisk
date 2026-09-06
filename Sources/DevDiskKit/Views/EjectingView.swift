import SwiftUI

struct EjectingView: View {
    @EnvironmentObject var store: DiskStore

    private var doneCount: Int {
        store.ejectSteps.filter {
            if case .pending = $0.state { return false }
            if case .running = $0.state { return false }
            return true
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section(title: "正在安全弹出",
                    aside: "\(doneCount) / \(store.ejectSteps.count)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.ejectSteps) { StepRow(step: $0) }
                }
            }
        }
    }
}

/// Pinned action area while an eject is running.
struct EjectingFooter: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(spacing: 7) {
            Button("中止") {
                store.screen = .connected
                store.refresh()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            Text("中止不会撤销已停止的进程")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, UI.hPad)
        .padding(.vertical, 11)
    }
}

struct StepRow: View {
    let step: EjectFlow.Step

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            icon
                .frame(width: 15)
                .padding(.top, 0.5)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isPending ? .tertiary : .primary)
                if let d = step.detail {
                    Text(d)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isFailed ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13)).foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 13)).foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 13)).foregroundStyle(.red)
        }
    }

    private var isPending: Bool {
        if case .pending = step.state { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = step.state { return true }
        return false
    }
}
