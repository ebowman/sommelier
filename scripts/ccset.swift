// ccset.swift: flip isAllowed for ie.boboco.mbdummy in Control Center's trackedApplications THROUGH cfprefsd (live hide/show, gdu.36).
// Build+sign: swiftc -O -o ccset ccset.swift && codesign -s - -f --entitlements ccset.entitlements ccset
// Usage: ./ccset ie.boboco.mbdummy 0|1     (refuses any other bundle id)
import Foundation
// usage: ccset <bundle> <0|1>   -- flips isAllowed through cfprefsd (CFPreferences), NOT a file write
let dom = (CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "group.com.apple.controlcenter") as CFString
let key = "trackedApplications" as CFString
let a = CommandLine.arguments
guard a.count >= 3, a[1] == "ie.boboco.mbdummy" else { print("only ie.boboco.mbdummy allowed"); exit(2) }
let allowed = a[2] == "1"
guard let blob = CFPreferencesCopyAppValue(key, dom) as? Data else { print("no blob"); exit(1) }
var f = PropertyListSerialization.PropertyListFormat.binary
var list = try PropertyListSerialization.propertyList(from: blob, options: [], format: &f) as! [Any]
var n = 0
for i in stride(from: 0, to: list.count, by: 2) {
  if let d = list[i] as? [String: Any], let b = d["bundle"] as? [String: Any], b["_0"] as? String == a[1], var v = list[i+1] as? [String: Any] {
    v["isAllowed"] = allowed; list[i+1] = v; n += 1 } }
guard n > 0 else { print("entry not found"); exit(1) }
let out = try PropertyListSerialization.data(fromPropertyList: list, format: f, options: 0)
CFPreferencesSetValue(key, out as CFData, dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
print("synchronize:", CFPreferencesSynchronize(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost), "entries changed:", n, "isAllowed=", allowed)
