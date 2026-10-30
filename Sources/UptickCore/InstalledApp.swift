import Foundation

public struct InstalledApp: Sendable {
    public enum Kind: Sendable {
        case mac
        /// iPhone or iPad app installed from the App Store on Apple silicon (`X.app/Wrapper/*.app`).
        case iosWrapper
    }

    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String?
    public let kind: Kind
    public let isAppStore: Bool
    public let appStoreItemID: Int?
    public let sparkleFeed: URL?
    public let electronFeed: ElectronFeed?

    public var fileName: String { url.lastPathComponent }
}

/// Update feed declared by electron-updater in `Contents/Resources/app-update.yml`.
public enum ElectronFeed: Sendable, Equatable {
    case generic(URL)
    case github(owner: String, repo: String)

    static func parse(_ yaml: String) -> ElectronFeed? {
        let fields = SimpleYAML.fields(yaml)
        switch fields["provider"] {
        case "generic":
            guard let raw = fields["url"], !raw.isEmpty, let url = URL(string: raw) else { return nil }
            return .generic(url)
        case "github":
            guard let owner = fields["owner"], let repo = fields["repo"] else { return nil }
            return .github(owner: owner, repo: repo)
        default:
            return nil
        }
    }
}

/// Reads the flat `key: value` lines that app-update.yml and latest-mac.yml use. Not a YAML parser.
enum SimpleYAML {
    static func fields(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix(" ") && !line.hasPrefix("-") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if result[key] == nil { result[key] = value }
        }
        return result
    }
}

public enum AppScanner {
    public static var defaultFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
    }

    /// Finds apps at the top level of each folder and one level down (e.g. /Applications/Utilities).
    public static func scan(folders: [URL] = defaultFolders) -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    if let app = read(item) { apps.append(app) }
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let nested = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    for sub in nested where sub.pathExtension == "app" {
                        if let app = read(sub) { apps.append(app) }
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func read(_ url: URL) -> InstalledApp? {
        let fm = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent

        let wrapperMeta = url.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        if let meta = NSDictionary(contentsOf: wrapperMeta) as? [String: Any],
           let bundleID = meta["softwareVersionBundleId"] as? String {
            return InstalledApp(
                url: url, name: name, bundleID: bundleID,
                version: meta["bundleShortVersionString"] as? String ?? "",
                build: meta["bundleVersion"] as? String,
                kind: .iosWrapper, isAppStore: true,
                appStoreItemID: (meta["itemId"] as? NSNumber)?.intValue,
                sparkleFeed: nil, electronFeed: nil
            )
        }

        let contents = url.appendingPathComponent("Contents")
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }

        let feed = (info["SUFeedURL"] as? String)
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let electron = (try? String(contentsOf: contents.appendingPathComponent("Resources/app-update.yml"), encoding: .utf8))
            .flatMap(ElectronFeed.parse)

        return InstalledApp(
            url: url, name: name, bundleID: bundleID,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String,
            kind: .mac,
            isAppStore: fm.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path),
            appStoreItemID: nil,
            sparkleFeed: feed, electronFeed: electron
        )
    }
}
