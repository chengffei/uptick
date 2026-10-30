import Foundation

public struct AppcastItem: Equatable {
    public var version: String?          // sparkle:version, compared with CFBundleVersion
    public var shortVersion: String?     // sparkle:shortVersionString, for display
    public var minimumSystemVersion: String?
    public var channel: String?
    public var downloadURL: URL?
}

/// Parses a Sparkle appcast. Handles both the element form (`<sparkle:version>`)
/// and the older attribute form on `<enclosure sparkle:version="…">`.
public final class AppcastParser: NSObject, XMLParserDelegate {
    private var items: [AppcastItem] = []
    private var current: AppcastItem?
    private var text = ""

    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    public func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                       qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = AppcastItem() }
        guard current != nil, name == "enclosure" else { return }
        if let url = attributes["url"] { current?.downloadURL = URL(string: url) }
        if current?.version == nil { current?.version = attributes["sparkle:version"] }
        if current?.shortVersion == nil { current?.shortVersion = attributes["sparkle:shortVersionString"] }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item":
            if let item = current { items.append(item) }
            current = nil
        case "sparkle:version": current?.version = value
        case "sparkle:shortVersionString": current?.shortVersion = value
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
        case "sparkle:channel": current?.channel = value
        default: break
        }
    }
}

extension AppcastItem {
    /// Newest stable item this Mac can run. Beta channels are skipped.
    static func best(of items: [AppcastItem], osVersion: OperatingSystemVersion) -> AppcastItem? {
        let os = Version("\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)")
        return items
            .filter { $0.channel == nil && ($0.version ?? $0.shortVersion) != nil }
            .filter { item in item.minimumSystemVersion.map { Version($0) <= os } ?? true }
            .max { Version($0.version ?? $0.shortVersion!) < Version($1.version ?? $1.shortVersion!) }
    }
}
