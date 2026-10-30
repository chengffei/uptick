import Foundation

/// What a downloaded package really contained, keyed by the version string the source advertised.
/// Lets a source with its own numbering (Homebrew "8.3.14" for Lark's 147.x) be compared exactly.
public struct LearnedVersions: Codable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let version: String
        public let build: String?

        public init(version: String, build: String?) {
            self.version = version
            self.build = build
        }
    }

    /// bundle ID → advertised version → package contents
    public private(set) var entries: [String: [String: Entry]] = [:]

    public init() {}

    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uptick/learned.json")
    }

    public static func load(from file: URL = defaultFile) -> LearnedVersions {
        guard let data = try? Data(contentsOf: file) else { return LearnedVersions() }
        return (try? JSONDecoder().decode(LearnedVersions.self, from: data)) ?? LearnedVersions()
    }

    public func save(to file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    public mutating func record(bundleID: String, advertised: String, contains entry: Entry) {
        entries[bundleID, default: [:]][advertised] = entry
    }

    /// Re-decides a result with the real package version when this advertised version was inspected before.
    public func apply(to result: CheckResult) -> CheckResult {
        guard let latest = result.latest, let entry = entries[result.app.bundleID]?[latest] else { return result }
        var updated = result
        updated.confident = true
        // The source serves something older than what is installed (CleanShot's old v3 feed vs 4.8):
        // it says nothing about the real latest version.
        if Version(entry.version) < Version(result.app.version) {
            updated.status = .unknown
            return updated
        }
        let newer: Bool
        if let remote = entry.build, let local = result.app.build, Version(entry.version) == Version(result.app.version) {
            newer = Version(local) < Version(remote)
        } else {
            newer = Version(result.app.version) < Version(entry.version)
        }
        updated.status = newer ? .updateAvailable : .upToDate
        return updated
    }
}
