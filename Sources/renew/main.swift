import Foundation
import RenewCore

// renew            list every app with its installed and latest version
// renew --updates  list only apps with an update

let onlyUpdates = CommandLine.arguments.contains("--updates")
let apps = AppScanner.scan()
let results = await Checker().check(apps)

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
