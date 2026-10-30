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
    /// Apps checked so far in the current run, and how many there are.
    private(set) var progress = (done: 0, total: 0)
    private(set) var jobs: [URL: Job] = [:]
    /// Apps whose files on disk were replaced after the running copy started (Chrome's own
    /// updater does this), so what the user sees in the app is older than what is installed.
    private(set) var awaitingRelaunch: Set<URL> = []
    private var learned = LearnedVersions.load()
    /// A newer Uptick on GitHub, if any, and what happened when the user installed it.
    private(set) var selfUpdate: CheckResult?
    private(set) var selfUpdateJob: Job?

    /// Snapshot helper: keep only these app names, so website screenshots show familiar apps.
    func keepOnly(_ names: Set<String>) {
        results = results.filter { names.contains($0.app.name) }
        awaitingRelaunch = []
        selfUpdate = nil
    }

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
        progress = (0, 0)
        defer { isChecking = false }
        async let ownUpdate = SelfUpdate.check()
        let apps = await Task.detached { AppScanner.scan() }.value
        progress = (0, apps.count)
        results = await Checker(learned: learned).check(apps) { done, total in
            Task { @MainActor in self.progress = (max(self.progress.done, done), total) }
        }
        jobs = [:]
        awaitingRelaunch = Set(apps.map(\.url).filter(Self.isAwaitingRelaunch))
        selfUpdate = await ownUpdate
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

    /// Replaces Uptick's own files, then starts the new copy and quits this one.
    func updateSelf() async {
        guard let update = selfUpdate else { return }
        selfUpdateJob = .working
        do {
            guard case .installed = try await Installer.run(update, quitRunning: false) else {
                selfUpdateJob = nil
                selfUpdate = nil
                return
            }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", update.app.url.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            selfUpdateJob = .failed(error.localizedDescription)
        }
    }

    func relaunch(_ result: CheckResult) async {
        let url = result.app.url
        let path = url.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL.path == path }
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        awaitingRelaunch.remove(url)
    }

    static func isAwaitingRelaunch(_ app: URL) -> Bool {
        let path = app.standardizedFileURL.path
        guard let modified = (try? app.appendingPathComponent("Contents/Info.plist")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == path && ($0.launchDate ?? .distantFuture) < modified
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
