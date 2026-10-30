import Foundation
import UptickCore

// uptick                 list every app with its installed and latest version
// uptick --updates       list only apps with an update
// uptick verify NAME...  download the update, read the app inside, and remember what it really is

let arguments = Array(CommandLine.arguments.dropFirst())
let apps = AppScanner.scan()
let results = await Checker().check(apps)

if arguments.first == "verify" {
    var learned = LearnedVersions.load()
    for name in arguments.dropFirst() {
        guard let result = results.first(where: { $0.app.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            print("\(name): not installed"); continue
        }
        guard let url = result.downloadURL, let advertised = result.latest else {
            print("\(name): no download known (\(result.source?.rawValue ?? "no source"))"); continue
        }
        print("\(name): downloading \(url.absoluteString)")
        do {
            let package = try await PackageInspector.inspect(url)
            let installedTeam = PackageInspector.teamID(of: result.app.url)
            guard package.bundleID == result.app.bundleID else {
                print("  package holds \(package.bundleID), not \(result.app.bundleID); wrong match, nothing recorded"); continue
            }
            guard installedTeam == nil || package.teamID == installedTeam else {
                print("  signed by \(package.teamID ?? "nobody"), installed app by \(installedTeam!); nothing recorded"); continue
            }
            learned.record(bundleID: package.bundleID, advertised: advertised,
                           contains: .init(version: package.version, build: package.build))
            let verdict = Version(result.app.version) < Version(package.version)
                || (Version(result.app.version) == Version(package.version)
                    && Version(result.app.build ?? "") < Version(package.build ?? ""))
            print("  \(result.source!.rawValue) says \(advertised); package is \(package.version) (\(package.build ?? "-")),"
                  + " installed \(result.app.version) (\(result.app.build ?? "-")) → \(verdict ? "real update" : "not newer")")
        } catch {
            print("  failed: \(error)")
        }
    }
    try learned.save()
    exit(0)
}

let onlyUpdates = arguments.contains("--updates")

func pad(_ s: String, _ width: Int) -> String {
    // CJK characters take two columns in a terminal.
    let w = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) }
    return s + String(repeating: " ", count: max(1, width - w))
}

let marks: [CheckResult.Status: String] = [.updateAvailable: "↑", .upToDate: "✓", .unknown: "?", .system: "-"]
for r in results where !onlyUpdates || r.status == .updateAvailable {
    print(pad(marks[r.status]! + (r.confident ? "" : "?"), 3) + pad(r.app.name, 34) + pad(r.app.version, 16)
          + pad(r.latest ?? "", 16) + (r.source?.rawValue ?? ""))
}

let thirdParty = results.filter { $0.status != .system }
let covered = thirdParty.filter { $0.status != .unknown }
let updates = results.filter { $0.status == .updateAvailable }
let unsure = covered.filter { !$0.confident }
var bySource: [String: Int] = [:]
for r in covered { bySource[r.source!.rawValue, default: 0] += 1 }
print("\n\(apps.count) apps, \(thirdParty.count) third-party, \(covered.count) covered"
      + " (\(thirdParty.isEmpty ? 0 : covered.count * 100 / thirdParty.count)%), \(updates.count) updates, \(unsure.count) need a look")
print(bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
