import SwiftUI
import UptickCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showUnknown = false

    var body: some View {
        List {
            section(.updates, title: "Updates", footer: nil)
            section(.review, title: "Needs a Look",
                    footer: "These versions may not compare correctly. Verify downloads the update and reads its real version; nothing is installed.")
            section(.current, title: "Up to Date", footer: nil)
            let unknown = model.items(in: .unknown)
            if !unknown.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showUnknown) {
                        ForEach(unknown, id: \.app.url) { AppRow(result: $0, group: .unknown) }
                    } label: {
                        header("Not Found", count: unknown.count)
                    }
                } footer: {
                    Text("No public update source knows these apps.")
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if model.results.isEmpty && model.isChecking {
                ProgressView("Checking…")
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
                Button("Update All") {
                    Task { await model.updateAll() }
                }
                .disabled(!model.hasInstallableUpdates || model.isChecking)
            }
        }
        .task {
            if model.results.isEmpty { await model.refresh() }
        }
    }

    private var subtitle: Text {
        if model.isChecking { return Text("Checking…") }
        guard let date = model.lastChecked else { return Text(verbatim: "") }
        return Text("Last checked \(date.formatted(date: .omitted, time: .shortened))")
    }

    @ViewBuilder
    private func section(_ group: Group, title: LocalizedStringKey, footer: LocalizedStringKey?) -> some View {
        let items = model.items(in: group)
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.app.url) { AppRow(result: $0, group: group) }
            } header: {
                header(title, count: items.count)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func header(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(verbatim: "\(count)").foregroundStyle(.secondary)
        }
        .font(.headline)
    }
}

struct AppRow: View {
    @Environment(AppModel.self) private var model
    let result: CheckResult
    let group: Group

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: result.app.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if case .failed(let message) = model.jobs[result.app.url] {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if model.awaitingRelaunch.contains(result.app.url) {
                    Text("Updated on disk. The running copy is older until you relaunch it.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if let source = result.source {
                    Text("via \(source.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            versions
            action.frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var versions: some View {
        let installed = result.app.version.isEmpty ? "–" : result.app.version
        let showsLatest = (group == .updates || group == .review) && result.latest != nil
        return Text(verbatim: showsLatest ? "\(installed)  →  \(result.latest!)" : installed)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var action: some View {
        switch model.jobs[result.app.url] {
        case .working:
            ProgressView().controlSize(.small)
        case .installed(let version):
            Text("Updated to \(version)").font(.callout).foregroundStyle(.secondary)
        case .alreadyCurrent:
            Text("Already current").font(.callout).foregroundStyle(.secondary)
        case .openedInstaller:
            Text("Installer opened").font(.callout).foregroundStyle(.secondary)
        case .failed:
            button("Retry")
        case nil where model.awaitingRelaunch.contains(result.app.url) && group != .updates:
            Button("Relaunch") { Task { await model.relaunch(result) } }.controlSize(.small)
        case nil:
            switch group {
            case .updates: button(result.source == .appStore ? "Open App Store" : "Update")
            case .review: button("Verify")
            case .current, .unknown: EmptyView()
            }
        }
    }

    private func button(_ title: LocalizedStringKey) -> some View {
        Button(title) { Task { await model.act(on: result) } }
            .controlSize(.small)
    }
}
