import Foundation

public enum UpdateSource: String, Sendable {
    case appStore = "App Store"
    case sparkle = "Sparkle"
    case electron = "Electron"
    case homebrew = "Homebrew"
}

public struct CheckResult: Sendable {
    public enum Status: Sendable {
        case updateAvailable
        case upToDate
        /// No source knows this app.
        case unknown
        /// Ships with macOS and updates with it.
        case system
    }

    public let app: InstalledApp
    public internal(set) var status: Status
    public let source: UpdateSource?
    public let latest: String?
    public internal(set) var downloadURL: URL?
    /// False when the answer rests on data known to be shaky: an App Store record shared with the
    /// iPhone app, or installed and latest versions that disagree on the major number.
    public var confident: Bool = true
}

public struct Checker {
    public var session: URLSession
    public var country: String
    public var cacheDirectory: URL
    public var learned: LearnedVersions

    public init(session: URLSession = .shared,
                country: String = Locale.current.region?.identifier.lowercased() ?? "us",
                cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Renew"),
                learned: LearnedVersions = .load()) {
        self.session = session
        self.learned = learned
        self.country = country
        self.cacheDirectory = cacheDirectory
    }

    public func check(_ apps: [InstalledApp]) async -> [CheckResult] {
        async let storeVersions = appStoreVersions(for: apps.filter(\.isAppStore))
        async let casks = loadCaskIndex()
        let store = await storeVersions
        let index = await casks

        return await withTaskGroup(of: (Int, CheckResult).self) { group in
            for (i, app) in apps.enumerated() {
                group.addTask { (i, await check(app, store: store, casks: index)) }
            }
            var results = [CheckResult?](repeating: nil, count: apps.count)
            for await (i, result) in group { results[i] = learned.apply(to: result) }
            return results.compactMap { $0 }
        }
    }

    func check(_ app: InstalledApp, store: [String: StoreRecord], casks: CaskIndex?) async -> CheckResult {
        if app.bundleID.hasPrefix("com.apple.") && !app.isAppStore {
            return CheckResult(app: app, status: .system, source: nil, latest: nil, downloadURL: nil)
        }
        if app.version.isEmpty {
            return CheckResult(app: app, status: .unknown, source: nil, latest: nil, downloadURL: nil)
        }
        if app.isAppStore, let record = store[app.bundleID] {
            // Only the desktopSoftware entity is reliable for Mac apps; the macSoftware fallback can
            // return the iPhone version of a universal purchase (百度网盘 8.9.7 vs 13.36.0).
            return compare(app, latest: record.version, source: .appStore, trusted: app.kind == .iosWrapper || record.desktop)
        }
        if let feed = app.sparkleFeed,
           let data = try? await fetch(feed),
           let item = AppcastItem.best(of: AppcastParser.parse(data), osVersion: ProcessInfo.processInfo.operatingSystemVersion) {
            let display = item.shortVersion ?? item.version ?? ""
            // Sparkle itself decides by CFBundleVersion vs sparkle:version, so do the same.
            let newer: Bool
            if let remote = item.version, let local = app.build {
                newer = Version(local) < Version(remote)
            } else {
                newer = Version(app.version) < Version(display)
            }
            return CheckResult(app: app, status: newer ? .updateAvailable : .upToDate,
                               source: .sparkle, latest: display, downloadURL: item.downloadURL,
                               confident: sameMajor(app.version, display))
        }
        if let feed = app.electronFeed, let (latest, download) = await electronRelease(feed) {
            var result = compare(app, latest: latest, source: .electron)
            result.downloadURL = download
            return result
        }
        if let cask = casks?.cask(for: app), let parts = CaskIndex.comparableVersions(cask.version) {
            // Any part matching the installed version or build means we already have it.
            let local = [app.version, app.build].compactMap { $0 }.map(Version.init)
            let alreadyHave = parts.contains { part in local.contains(Version(part)) }
            let newer = !alreadyHave && Version(app.version) < Version(parts[0])
            return CheckResult(app: app, status: newer ? .updateAvailable : .upToDate,
                               source: .homebrew, latest: parts[0], downloadURL: cask.downloadURL,
                               confident: alreadyHave || sameMajor(app.version, parts[0]))
        }
        return CheckResult(app: app, status: .unknown, source: nil, latest: nil, downloadURL: nil)
    }

    func compare(_ app: InstalledApp, latest: String, source: UpdateSource, trusted: Bool = true) -> CheckResult {
        let newer = Version(app.version) < Version(latest)
        return CheckResult(app: app, status: newer ? .updateAvailable : .upToDate,
                           source: source, latest: latest, downloadURL: nil,
                           confident: trusted && sameMajor(app.version, latest))
    }

    /// A different major number usually means two version schemes (Chromium-style app version
    /// vs marketing version, renumbered releases), not a real gap. Worth a human look either way.
    func sameMajor(_ a: String, _ b: String) -> Bool {
        Version(a).tokens.first == Version(b).tokens.first
    }

    // MARK: - Sources

    /// One batched lookup per store region; falls back to the US store for apps the local store lacks.
    struct StoreRecord: Sendable {
        let version: String
        /// Found through entity=desktopSoftware, which returns the Mac build's metadata.
        let desktop: Bool
    }

    /// Batched lookups per store region, local region first, then the US store for apps it lacks.
    /// Mac apps try entity=desktopSoftware before the broader macSoftware (same order as Latest).
    func appStoreVersions(for apps: [InstalledApp]) async -> [String: StoreRecord] {
        var found: [String: StoreRecord] = [:]
        for region in [country] + (country == "us" ? [] : ["us"]) {
            for entity in ["desktopSoftware", "macSoftware"] {
                let mac = apps.filter { $0.kind == .mac && found[$0.bundleID] == nil }.map(\.bundleID)
                guard !mac.isEmpty else { break }
                await lookup([.init(name: "bundleId", value: mac.joined(separator: ",")), .init(name: "entity", value: entity)],
                             region: region, desktop: entity == "desktopSoftware", into: &found)
            }
            let ios = apps.filter { $0.kind == .iosWrapper && found[$0.bundleID] == nil }.compactMap(\.appStoreItemID)
            if !ios.isEmpty {
                await lookup([.init(name: "id", value: ios.map(String.init).joined(separator: ","))],
                             region: region, desktop: false, into: &found)
            }
        }
        return found
    }

    private func lookup(_ query: [URLQueryItem], region: String, desktop: Bool, into found: inout [String: StoreRecord]) async {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = query + [.init(name: "country", value: region)]
        guard let data = try? await fetch(components.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return }
        for result in results {
            if let id = result["bundleId"] as? String, let version = result["version"] as? String, found[id] == nil {
                found[id] = StoreRecord(version: version, desktop: desktop)
            }
        }
    }

    func electronRelease(_ feed: ElectronFeed) async -> (version: String, download: URL?)? {
        switch feed {
        case .generic(let base):
            guard let data = try? await fetch(base.appendingPathComponent("latest-mac.yml")),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let fields = SimpleYAML.fields(text)
            guard let version = fields["version"] else { return nil }
            let download = fields["path"].flatMap { URL(string: $0, relativeTo: base.appendingPathComponent("")) }
            return (version, download?.absoluteURL)
        case .github(let owner, let repo):
            guard let data = try? await fetch(URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return nil }
            return (tag, nil)
        }
    }

    /// Homebrew's cask list is ~20 MB, so keep a copy for a day and fall back to a stale one offline.
    func loadCaskIndex() async -> CaskIndex? {
        let file = cacheDirectory.appendingPathComponent("cask.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 24 * 3600, let data = try? await fetch(CaskIndex.remote, timeout: 60) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? CaskIndex(json: data)
    }

    func fetch(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Renew", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
