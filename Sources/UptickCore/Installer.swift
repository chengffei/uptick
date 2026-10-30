import AppKit
import Security

public enum InstallOutcome: Sendable {
    /// The new version is in place. `wasRunning` apps have been relaunched.
    case installed(InspectedApp)
    /// The package was not newer than the installed app; nothing changed.
    case notNewer(InspectedApp)
    /// A pkg installer was saved to Downloads and opened in Installer.
    case openedInstaller(URL)
}

public enum InstallError: Error, LocalizedError {
    case noDownload
    case wrongApp(String)
    case differentDeveloper(String?)
    case invalidSignature
    case stillRunning
    /// macOS blocked the change. The fix is System Settings › Privacy & Security › App Management.
    case notPermitted
    case copyFailed(String)

    /// Looked up in the main bundle, so the app's Localizable.strings translates them.
    public var errorDescription: String? {
        func text(_ key: String, _ args: CVarArg...) -> String {
            String(format: NSLocalizedString(key, comment: ""), arguments: args)
        }
        switch self {
        case .noDownload: return text("No download is known for this app.")
        case .wrongApp(let id): return text("The download contains a different app (%@).", id)
        case .differentDeveloper(let team): return text("The download is signed by another developer (%@).", team ?? "unsigned")
        case .invalidSignature: return text("The download's code signature is not valid.")
        case .stillRunning: return text("The app did not quit. Quit it and try again.")
        case .notPermitted: return text("macOS did not allow Uptick to change this app. Turn on Uptick under Privacy & Security › App Management.")
        case .copyFailed(let message): return text("Copying the new version failed: %@", message)
        }
    }
}

/// Replaces an installed app with the version from its update package.
/// The old copy goes to the Trash, so a bad update can be undone by hand.
public enum Installer {
    /// Downloads and checks the update, then installs it unless `inspectOnly` is set.
    public static func run(_ result: CheckResult, inspectOnly: Bool = false) async throws -> InstallOutcome {
        guard let url = result.downloadURL else { throw InstallError.noDownload }
        let file = try await PackageInspector.download(url)

        let package: PreparedPackage
        do {
            package = try PackageInspector.prepare(file)
        } catch InspectError.unsupportedFormat("pkg") {
            return .openedInstaller(try await openInstaller(file, name: url.lastPathComponent))
        }
        defer { package.close() }

        let app = result.app
        guard package.info.bundleID == app.bundleID else { throw InstallError.wrongApp(package.info.bundleID) }
        let installedTeam = PackageInspector.teamID(of: app.url)
        if let installedTeam, package.info.teamID != installedTeam {
            throw InstallError.differentDeveloper(package.info.teamID)
        }
        guard isValidlySigned(package.app) else { throw InstallError.invalidSignature }

        let newer = Version(app.version) < Version(package.info.version)
            || (Version(app.version) == Version(package.info.version)
                && Version(app.build ?? "") < Version(package.info.build ?? ""))
        guard newer, !inspectOnly else { return .notNewer(package.info) }

        let wasRunning = try await quit(app.url)
        try replace(app.url, with: package.app)
        if wasRunning {
            _ = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: .init())
        }
        return .installed(package.info)
    }

    static func isValidlySigned(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
    }

    /// Asks the app at this exact path to quit and waits up to ten seconds. Returns whether it was running.
    /// Matching by path, not bundle ID, so another copy of the same app elsewhere keeps running.
    @MainActor
    static func quit(_ app: URL) async throws -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        }
        guard !running.isEmpty else { return false }
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if running.contains(where: { !$0.isTerminated }) { throw InstallError.stillRunning }
        return true
    }

    static func replace(_ installed: URL, with new: URL) throws {
        let fm = FileManager.default
        var trashed: NSURL?
        do {
            try fm.trashItem(at: installed, resultingItemURL: &trashed)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            throw InstallError.notPermitted
        }
        do {
            try PackageInspector.run("/usr/bin/ditto", [new.path, installed.path])
        } catch {
            // Put the old version back so the user is never left without the app.
            if let trashed = trashed as URL? {
                try? fm.removeItem(at: installed)
                try? fm.moveItem(at: trashed, to: installed)
            }
            throw InstallError.copyFailed("\(error)")
        }
    }

    @MainActor
    static func openInstaller(_ file: URL, name: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = downloads.appendingPathComponent(name.hasSuffix(".pkg") ? name : "\(name).pkg")
        if FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(target.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: file, to: target)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        NSWorkspace.shared.open(target)
        return target
    }
}
