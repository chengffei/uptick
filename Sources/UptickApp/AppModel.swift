import AppKit
import Observation
import UptickCore

enum Group: CaseIterable {
    case updates, review, current, unknown
}

/// What happened to one app after the user pressed its button.
enum Job: Equatable {
    case working
    case installed(String)
    case alreadyCurrent
    case openedInstaller
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    private(set) var results: [CheckResult] = []
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    private(set) var jobs: [URL: Job] = [:]
    private var learned = LearnedVersions.load()

    func items(in group: Group) -> [CheckResult] {
        results.filter { result in
            guard result.status != .system, result.app.bundleID != Bundle.main.bundleIdentifier else { return false }
            switch group {
            case .updates: return result.status == .updateAvailable && result.confident
            case .review: return result.status != .unknown && !result.confident
            case .current: return result.status == .upToDate && result.confident
            case .unknown: return result.status == .unknown
            }
        }
    }

    var hasInstallableUpdates: Bool {
        items(in: .updates).contains { $0.source != .appStore && jobs[$0.app.url] == nil }
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let apps = await Task.detached { AppScanner.scan() }.value
        results = await Checker(learned: learned).check(apps)
        jobs = [:]
        lastChecked = Date()
    }

    /// The button on a row: App Store apps open their page, confirmed updates install,
    /// uncertain ones are verified first (download and read, nothing installed).
    func act(on result: CheckResult) async {
        if result.source == .appStore {
            openStorePage(result)
            return
        }
        let verifyOnly = !result.confident
        jobs[result.app.url] = .working
        do {
            switch try await Installer.run(result, inspectOnly: verifyOnly) {
            case .installed(let info):
                remember(result, info)
                jobs[result.app.url] = .installed(info.version)
            case .notNewer(let info):
                remember(result, info)
                jobs[result.app.url] = nil
                if !verifyOnly { jobs[result.app.url] = .alreadyCurrent }
                await recheck(result)
            case .openedInstaller:
                jobs[result.app.url] = .openedInstaller
            }
        } catch {
            jobs[result.app.url] = .failed(error.localizedDescription)
        }
    }

    func updateAll() async {
        for result in items(in: .updates) where result.source != .appStore && jobs[result.app.url] == nil {
            await act(on: result)
        }
    }

    private func remember(_ result: CheckResult, _ info: InspectedApp) {
        guard let advertised = result.latest else { return }
        learned.record(bundleID: info.bundleID, advertised: advertised, contains: .init(version: info.version, build: info.build))
        try? learned.save()
    }

    /// Re-decides one row with what was just learned, without checking every app again.
    private func recheck(_ result: CheckResult) async {
        guard let app = AppScanner.read(result.app.url),
              let fresh = await Checker(learned: learned).check([app]).first,
              let index = results.firstIndex(where: { $0.app.url == result.app.url }) else { return }
        results[index] = fresh
    }

    private func openStorePage(_ result: CheckResult) {
        guard let page = result.storePage else { return }
        // macappstore:// opens the App Store app directly instead of the browser.
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.scheme = "macappstore"
        NSWorkspace.shared.open(components?.url ?? page)
    }
}
