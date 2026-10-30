import Foundation

public struct Cask: Equatable, Sendable {
    public let token: String
    public let version: String
    public let downloadURL: URL?
    public let appNames: [String]
    /// Whether the cask's uninstall or zap stanzas mention the app's bundle ID, i.e. a confirmed match.
    let rawText: String

    func mentions(_ bundleID: String) -> Bool { rawText.contains(bundleID) }
}

/// Index of Homebrew's public cask list (formulae.brew.sh/api/cask.json), keyed by .app file name.
public struct CaskIndex: Sendable {
    let byAppName: [String: [Cask]]

    public static let remote = URL(string: "https://formulae.brew.sh/api/cask.json")!

    public init(json: Data) throws {
        guard let list = try JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var index: [String: [Cask]] = [:]
        for entry in list {
            guard let token = entry["token"] as? String, let version = entry["version"] as? String else { continue }
            let artifacts = entry["artifacts"] as? [[String: Any]] ?? []
            var names: [String] = []
            for artifact in artifacts {
                for item in artifact["app"] as? [Any] ?? [] {
                    if let name = item as? String {
                        names.append(name)
                    } else if let target = (item as? [String: Any])?["target"] as? String {
                        names.append((target as NSString).lastPathComponent)
                    }
                }
            }
            guard !names.isEmpty else { continue }
            let raw = (try? JSONSerialization.data(withJSONObject: artifacts)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let cask = Cask(token: token, version: version,
                            downloadURL: (entry["url"] as? String).flatMap(URL.init(string:)),
                            appNames: names, rawText: raw)
            for name in names { index[name, default: []].append(cask) }
        }
        byAppName = index
    }

    /// Picks the cask for an installed app. A bundle-ID mention wins; otherwise prefer the
    /// plain token over variants like `foo@beta`.
    public func cask(for app: InstalledApp) -> Cask? {
        guard let candidates = byAppName[app.fileName], !candidates.isEmpty else { return nil }
        if let confirmed = candidates.first(where: { $0.mentions(app.bundleID) }) { return confirmed }
        return candidates.min { a, b in
            (a.token.contains("@") ? 1 : 0, a.token.count) < (b.token.contains("@") ? 1 : 0, b.token.count)
        }
    }

    /// Homebrew versions often append a build after a comma: "6.2.1,62100".
    /// Returns nil for unversioned casks ("latest").
    public static func comparableVersions(_ caskVersion: String) -> [String]? {
        guard caskVersion != "latest" else { return nil }
        return caskVersion.split(separator: ",").map(String.init)
    }
}
