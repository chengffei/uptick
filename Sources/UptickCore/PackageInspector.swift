import Foundation
import Security

/// The app found inside a downloaded update.
public struct InspectedApp: Sendable {
    public let bundleID: String
    public let version: String
    public let build: String?
    public let teamID: String?
}

public enum InspectError: Error, LocalizedError, CustomStringConvertible {
    case unsupportedFormat(String)
    case noApp
    case tool(String)
    /// The server answered with an error status instead of the package.
    case httpStatus(Int)
    /// The server sent a web page (often an error or login page) instead of the package.
    case webPage

    /// Looked up in the main bundle, so the app's Localizable.strings translates them.
    public var errorDescription: String? {
        func text(_ key: String, _ args: CVarArg...) -> String {
            String(format: NSLocalizedString(key, comment: ""), arguments: args)
        }
        switch self {
        case .unsupportedFormat(let format): return text("The download is not a zip or dmg (%@).", format)
        case .noApp: return text("No app was found inside the download.")
        case .tool(let message): return message
        case .httpStatus(let code): return text("The download server answered with error %d.", code)
        case .webPage: return text("The download server sent a web page instead of the app. The vendor may block direct downloads.")
        }
    }

    public var description: String { errorDescription ?? "" }
}

/// An unpacked update: the app inside a zip or a mounted dmg. Call `close()` when done.
public final class PreparedPackage {
    public let app: URL
    public let info: InspectedApp
    let work: URL
    let mount: URL?

    init(app: URL, info: InspectedApp, work: URL, mount: URL?) {
        self.app = app
        self.info = info
        self.work = work
        self.mount = mount
    }

    public func close() {
        if let mount { try? PackageInspector.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        try? FileManager.default.removeItem(at: work)
    }
}

/// Downloads an update package (zip or dmg), finds the app inside, and reads its identity.
public enum PackageInspector {
    /// Reads what an update contains without installing anything.
    public static func inspect(_ url: URL, session: URLSession = .shared) async throws -> InspectedApp {
        let file = try await download(url, session: session)
        let package = try prepare(file)
        defer { package.close() }
        return package.info
    }

    /// Downloads into a fresh temporary folder and returns the file. The folder belongs to the caller.
    public static func download(_ url: URL, session: URLSession = .shared) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("uptick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("Uptick", forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: work)
            throw InspectError.httpStatus(http.statusCode)
        }
        let file = work.appendingPathComponent("package")
        try FileManager.default.moveItem(at: downloaded, to: file)
        return file
    }

    /// Unpacks a downloaded zip or dmg. Throws `unsupportedFormat` for anything else (e.g. pkg).
    public static func prepare(_ file: URL) throws -> PreparedPackage {
        let work = file.deletingLastPathComponent()
        do {
            switch try format(of: file) {
            case "zip":
                let out = work.appendingPathComponent("unzipped")
                try run("/usr/bin/ditto", ["-x", "-k", file.path, out.path])
                let app = try findApp(in: out)
                return PreparedPackage(app: app, info: try read(app), work: work, mount: nil)
            case "dmg":
                let mount = work.appendingPathComponent("mount")
                try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-noautoopen",
                                             "-mountpoint", mount.path, file.path])
                do {
                    let app = try findApp(in: mount)
                    return PreparedPackage(app: app, info: try read(app), work: work, mount: mount)
                } catch {
                    try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
                    throw error
                }
            case "web":
                throw InspectError.webPage
            case let other:
                throw InspectError.unsupportedFormat(other)
            }
        } catch InspectError.unsupportedFormat(let format) {
            throw InspectError.unsupportedFormat(format)   // keep the download for the caller
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Identifies the archive by its magic bytes; download URLs often hide the extension.
    static func format(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4) ?? Data()
        if head.starts(with: [0x50, 0x4B]) { return "zip" }
        if head.starts(with: [0x78, 0x61, 0x72, 0x21]) { return "pkg" }
        if let text = String(data: head, encoding: .ascii), text.hasPrefix("<") || text.hasPrefix("{") { return "web" }
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
