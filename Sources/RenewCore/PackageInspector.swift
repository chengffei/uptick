import Foundation
import Security

/// The app found inside a downloaded update.
public struct InspectedApp: Sendable {
    public let bundleID: String
    public let version: String
    public let build: String?
    public let teamID: String?
}

public enum InspectError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case noApp
    case tool(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let ext): return "unsupported package format: \(ext)"
        case .noApp: return "no .app found in package"
        case .tool(let message): return message
        }
    }
}

/// Downloads an update package (zip or dmg), finds the app inside, and reads its identity.
/// Nothing is installed; the temporary copy is removed afterwards.
public enum PackageInspector {
    public static func inspect(_ url: URL, session: URLSession = .shared) async throws -> InspectedApp {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("renew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Renew", forHTTPHeaderField: "User-Agent")
        let (downloaded, _) = try await session.download(for: request)
        let package = work.appendingPathComponent("package")
        try FileManager.default.moveItem(at: downloaded, to: package)

        switch try format(of: package) {
        case "zip":
            let out = work.appendingPathComponent("unzipped")
            try run("/usr/bin/ditto", ["-x", "-k", package.path, out.path])
            return try read(findApp(in: out))
        case "dmg":
            let mount = work.appendingPathComponent("mount")
            try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                         "-mountpoint", mount.path, package.path])
            defer { try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            return try read(findApp(in: mount))
        case let other:
            throw InspectError.unsupportedFormat(other)
        }
    }

    /// Identifies the archive by its magic bytes; download URLs often hide the extension.
    static func format(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4) ?? Data()
        if head.starts(with: [0x50, 0x4B]) { return "zip" }
        if head.starts(with: [0x78, 0x61, 0x72, 0x21]) { return "pkg" }
        // UDIF disk images end with a 512-byte "koly" trailer.
        let size = try handle.seekToEnd()
        if size >= 512 {
            try handle.seek(toOffset: size - 512)
            if try handle.read(upToCount: 4) == Data("koly".utf8) { return "dmg" }
        }
        return "unknown"
    }

    /// Shallowest .app wins, so helper apps nested inside the main bundle are ignored.
    static func findApp(in folder: URL) throws -> URL {
        let fm = FileManager.default
        var level = [folder]
        for _ in 0..<3 {
            var next: [URL] = []
            for dir in level {
                let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
                if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
                next += items.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                        .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
                }
            }
            level = next
        }
        throw InspectError.noApp
    }

    public static func read(_ app: URL) throws -> InspectedApp {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { throw InspectError.noApp }
        return InspectedApp(bundleID: bundleID,
                            version: info["CFBundleShortVersionString"] as? String ?? "",
                            build: info["CFBundleVersion"] as? String,
                            teamID: teamID(of: app))
    }

    public static func teamID(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InspectError.tool("\((tool as NSString).lastPathComponent) failed: \(output.prefix(200))")
        }
    }
}
