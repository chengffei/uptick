import Foundation

/// Uptick's own updates come from its GitHub releases. Files downloaded this way carry no
/// quarantine flag, so after the first manual approval later versions open without a prompt.
public enum SelfUpdate {
    public static let repo = "chengffei/uptick"

    /// Reads the latest tag from the releases/latest redirect, which unlike the GitHub API
    /// has no anonymous rate limit.
    public static func latestVersion(session: URLSession = .shared) async -> String? {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("Uptick", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let tag = response.url?.lastPathComponent, tag.hasPrefix("v") else { return nil }
        return String(tag.dropFirst())
    }

    /// An update for the running copy of Uptick, or nil when it is current.
    public static func check(bundle: Bundle = .main, session: URLSession = .shared) async -> CheckResult? {
        guard let app = AppScanner.read(bundle.bundleURL),
              let latest = await latestVersion(session: session),
              Version(app.version) < Version(latest) else { return nil }
        return CheckResult(app: app, status: .updateAvailable, source: .github, latest: latest,
                           downloadURL: URL(string: "https://github.com/\(repo)/releases/download/v\(latest)/Uptick.zip"))
    }
}
