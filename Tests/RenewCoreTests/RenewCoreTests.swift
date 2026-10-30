import XCTest
@testable import RenewCore

final class VersionTests: XCTestCase {
    func testEqualIgnoringTrailingZerosAndPrefix() {
        XCTAssertEqual(Version("2.0"), Version("2.0.0"))
        XCTAssertEqual(Version("v1.4"), Version("1.4"))
        XCTAssertEqual(Version("3"), Version("3.0"))
    }

    func testOrdering() {
        XCTAssertLessThan(Version("1.9"), Version("1.10"))
        XCTAssertLessThan(Version("1.0b2"), Version("1.0"))
        XCTAssertLessThan(Version("1.0"), Version("1.0.1"))
        XCTAssertLessThan(Version("1.0beta"), Version("1.0rc"))
        XCTAssertLessThan(Version("2024.1 (241)"), Version("2024.2"))
        XCTAssertFalse(Version("2.0") < Version("2.0.0"))
    }

    func testHugeNumbersDoNotCrash() {
        XCTAssertLessThan(Version("1.0.20240101123045999999"), Version("2"))
    }
}

final class AppcastTests: XCTestCase {
    let xml = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
      <item><sparkle:version>120</sparkle:version><sparkle:shortVersionString>1.2</sparkle:shortVersionString>
        <enclosure url="https://x/1.2.zip"/></item>
      <item><enclosure url="https://x/1.3.zip" sparkle:version="130" sparkle:shortVersionString="1.3"/>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion></item>
      <item><sparkle:version>200</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
      <item><sparkle:version>300</sparkle:version><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
    </channel></rss>
    """

    func testParsesBothForms() {
        let items = AppcastParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[1].version, "130")
        XCTAssertEqual(items[1].shortVersion, "1.3")
        XCTAssertEqual(items[1].downloadURL?.absoluteString, "https://x/1.3.zip")
    }

    func testBestSkipsBetaAndUnsupportedOS() {
        let items = AppcastParser.parse(Data(xml.utf8))
        let best = AppcastItem.best(of: items, osVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(best?.shortVersion, "1.3")
    }
}

final class FeedTests: XCTestCase {
    func testElectronGeneric() {
        let yaml = "provider: generic\nurl: 'https://cdn.example.com/app'\nupdaterCacheDirName: x-updater\n"
        XCTAssertEqual(ElectronFeed.parse(yaml), .generic(URL(string: "https://cdn.example.com/app")!))
    }

    func testElectronEmptyURLIsIgnored() {
        XCTAssertNil(ElectronFeed.parse("provider: generic\nurl: ''\n"))
    }

    func testElectronGitHub() {
        XCTAssertEqual(ElectronFeed.parse("owner: a\nrepo: b\nprovider: github\n"), .github(owner: "a", repo: "b"))
    }

    func testLatestMacYAMLTakesTopLevelVersion() {
        let yaml = "version: 2.3.1\nfiles:\n  - url: a.zip\n    version: 9\npath: a.zip\n"
        XCTAssertEqual(SimpleYAML.fields(yaml)["version"], "2.3.1")
    }
}

final class CaskTests: XCTestCase {
    let json = """
    [
      {"token":"foo","version":"2.0,200","url":"https://x/foo.dmg",
       "artifacts":[{"app":["Foo.app"]},{"zap":[{"trash":"~/Library/Preferences/com.foo.app.plist"}]}]},
      {"token":"foo@beta","version":"3.0b1","artifacts":[{"app":["Foo.app"]}]},
      {"token":"other-foo","version":"9.0","artifacts":[{"app":["Foo.app"]},{"uninstall":[{"quit":"com.other.foo"}]}]},
      {"token":"bar","version":"latest","artifacts":[{"app":[{"target":"Bar.app"}]}]},
      {"token":"cli","version":"1.0","artifacts":[{"binary":["cli"]}]}
    ]
    """

    func app(_ file: String, id: String) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(file)"), name: file, bundleID: id, version: "1.0",
                     build: nil, kind: .mac, isAppStore: false, appStoreItemID: nil, sparkleFeed: nil, electronFeed: nil)
    }

    func testPrefersBundleIDMention() throws {
        let index = try CaskIndex(json: Data(json.utf8))
        XCTAssertEqual(index.cask(for: app("Foo.app", id: "com.other.foo"))?.token, "other-foo")
    }

    func testFallsBackToPlainToken() throws {
        let index = try CaskIndex(json: Data(json.utf8))
        XCTAssertEqual(index.cask(for: app("Foo.app", id: "com.unrelated"))?.token, "foo")
    }

    func testTargetNameAndLatest() throws {
        let index = try CaskIndex(json: Data(json.utf8))
        XCTAssertEqual(index.cask(for: app("Bar.app", id: "x"))?.token, "bar")
        XCTAssertNil(CaskIndex.comparableVersions("latest"))
        XCTAssertEqual(CaskIndex.comparableVersions("2.0,200"), ["2.0", "200"])
    }
}
