import Foundation

/// 9o9.15: THE rule for the name a menu bar item shows in the overflow panel and the Arrange strip.
///
/// A status item whose button shows an SF Symbol and sets no title exposes the symbol's accessibility label as its AX description
/// ("Shield Lefthalf Filled With A Check…"), and other apps expose a tooltip, a live value ("65%"), a date or "menubar image" there.
/// Those must never beat the app name. The description only names an item when the owner has several items and the description is a real,
/// distinct label (iStat Menus' "iStat Menus Network"). Pure: no AppKit, no I/O.
///
///  1. Owner with exactly ONE item among all known keys -> the app name (`ownerName`); for a Control Center / SystemUIServer module
///     (`.module` key) the module's human name ("Clock", "Time Machine", "Wi-Fi"), derived from the key.
///  2. Owner with several items -> each item's description (else title) when it is a real label that differs per item, else "<app> (n)"
///     numbered by record order.
///  3. The raw description stays available as `detail` (tooltip second line, logs, Filter).
public enum RowNameRule {
    public static let maxNameLength = 24

    // MARK: the heuristic

    /// SF-Symbol-vocabulary words (lowercased) that show up in symbol accessibility labels.
    static let symbolWords: Set<String> = [
        "shield", "lefthalf", "righthalf", "filled", "badge", "checkmark", "check", "with", "a", "an", "and", "circle", "square", "fill",
        "slash", "arrow", "arrows", "up", "down", "left", "right", "bolt", "gear", "gearshape", "wifi", "antenna", "radiowaves", "lock",
        "unlock", "key", "eye", "mic", "microphone", "camera", "bell", "bookmark", "star", "heart", "flag", "tray", "doc", "document",
        "folder", "scroll", "script", "bubble", "rectangle", "triangle", "exclamationmark", "xmark", "plus", "minus", "person", "hexagon",
        "diamond", "cloud", "sun", "moon", "drop", "trash", "pin", "tag", "link", "globe", "network", "externaldrive", "lightbulb", "clock",
        "play", "pause", "stop", "forward", "backward", "dot", "dots", "ellipsis", "stack", "layers", "grid", "list", "line", "lines",
        "horizontal", "vertical", "half", "outline", "on", "off", "inverse", "rotate", "clockwise", "counterclockwise", "shape", "symbol",
    ]
    static let placeholders: Set<String> = ["image", "icon", "menu", "menubar image", "menu bar image", "menubar", "menu bar", "item",
                                            "status item", "button", "statusitem", "menu extra"]

    /// True when `text` is not a usable item label: empty, an SF-Symbol accessibility label, a live value (digits, percent, date), a tooltip
    /// sentence (punctuation, or longer than 24 characters with 4+ words) or a generic placeholder ("menubar image").
    public static func isSymbolOrLiveLabel(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.contains(where: { $0.isNumber || $0 == "%" }) { return true }
        if t.contains(where: { ",…:;—–".contains($0) }) || t.contains("...") || t.contains(" - ") { return true }
        let words = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count >= 4 && t.count > maxNameLength { return true }
        let lower = t.lowercased()
        if placeholders.contains(lower) || lower.hasSuffix(" image") || lower.hasSuffix(" icon") { return true }
        let titleCase = words.allSatisfy { $0.first?.isUppercase ?? false }
        if titleCase, words.count >= 2 {
            let hits = words.filter { symbolWords.contains($0.lowercased()) }.count
            if hits >= 2 && hits * 2 >= words.count { return true }
        }
        return false
    }

    // MARK: module names

    static let moduleOverrides: [String: String] = [
        "clock": "Clock", "controlcenter": "Control Center", "focus": "Focus", "focusmode": "Focus", "wifi": "Wi-Fi", "timemachine": "Time Machine",
        "battery": "Battery", "bluetooth": "Bluetooth", "sound": "Sound", "volume": "Sound", "display": "Display", "airdrop": "AirDrop",
        "airplay": "AirPlay", "screenmirroring": "Screen Mirroring", "nowplaying": "Now Playing", "spotlight": "Spotlight", "siri": "Siri",
        "vpn": "VPN", "fastuserswitching": "Fast User Switching", "userswitcher": "Fast User Switching", "keyboardbrightness": "Keyboard Brightness",
        "stagemanager": "Stage Manager", "hearing": "Hearing", "accessibilityshortcuts": "Accessibility Shortcuts", "textinput": "Input Menu",
        "inputmenu": "Input Menu", "keyboard": "Input Menu", "textinputmenu": "Input Menu", "user": "Fast User Switching", "script": "Script Menu",
        "scriptmenu": "Script Menu", "accessibility": "Accessibility Shortcuts", "sleep": "Sleep", "eject": "Eject", "weather": "Weather", "musicrecognition": "Music Recognition", "audiovideomodule": "Mic and Camera",
    ]

    /// Human name of a Control Center / SystemUIServer module from its store name: the last dot component, a known Apple name from the
    /// override table, else its camel-case words ("com.apple.menuextra.TimeMachine" -> "Time Machine").
    public static func moduleName(_ name: String) -> String {
        let last = name.split(separator: ".").last.map(String.init) ?? name
        let norm = last.lowercased().filter { $0.isLetter || $0.isNumber }
        if let o = moduleOverrides[norm] { return o }
        var out = ""
        var prev: Character?
        for ch in last {
            if let p = prev, (ch.isUppercase && (p.isLowercase || p.isNumber)) || (ch.isNumber && p.isLetter) { out.append(" ") }
            out.append(ch); prev = ch
        }
        let s = out.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard let f = s.first else { return name }
        return f.uppercased() + s.dropFirst()
    }

    // MARK: the namer

    private static func clip(_ s: String, to n: Int = maxNameLength) -> String { s.count <= n ? s : String(s.prefix(max(1, n - 1))) + "…" }

    /// Names every key of one render/pass consistently. Build it once from the layout plus the observed items (`keys` in record order
    /// first; observed-only keys follow in a stable order).
    public struct Namer: Sendable {
        let items: [ItemKey: ItemInfo]
        /// Owner id -> that owner's keys in record order.
        let owners: [String: [ItemKey]]
        /// Owner id -> that owner's heuristic keys (counted only when the owner has no status key).
        let heuristics: [String: [ItemKey]]

        public init(keys: [ItemKey], items: [ItemKey: ItemInfo]) {
            var all: [ItemKey] = []
            var seen = Set<ItemKey>()
            for k in keys where seen.insert(k).inserted { all.append(k) }
            for k in items.keys.sorted(by: { $0.description < $1.description }) where seen.insert(k).inserted { all.append(k) }
            var o: [String: [ItemKey]] = [:]
            for k in all { if let id = RowNameRule.ownerID(k), case .status = k { o[id, default: []].append(k) } }
            // Heuristic keys are fingerprints of items that usually also have a status key: they count only for owners with none.
            let statusOwners = Set(o.keys)
            for k in all { if let id = RowNameRule.ownerID(k), case .heuristic = k, !statusOwners.contains(id) { o[id, default: []].append(k) } }
            var hs: [String: [ItemKey]] = [:]
            for k in all { if let id = RowNameRule.ownerID(k), case .heuristic = k { hs[id, default: []].append(k) } }
            self.items = items; self.owners = o; self.heuristics = hs
        }

        public init(layout: Layout, items: [ItemKey: ItemInfo]) { self.init(keys: layout.allKeys, items: items) }

        static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// The raw description (else title) as the app reports it: the join evidence for tooltips and logs. Empty when unknown.
        public func detail(_ k: ItemKey) -> String {
            guard let i = items[k] else { return "" }
            let d = Self.trimmed(i.axDescription)
            return d.isEmpty ? Self.trimmed(i.title) : d
        }

        /// A real, usable label for this item alone (description first, then title), "" when neither is.
        func label(_ k: ItemKey) -> String {
            guard let i = items[k] else { return "" }
            return [i.axDescription, i.title].map(Self.trimmed).first { !RowNameRule.isSymbolOrLiveLabel($0) } ?? ""
        }

        func appName(_ k: ItemKey, _ i: ItemInfo) -> String {
            let n = Self.trimmed(i.ownerName)
            return n.isEmpty ? "" : n
        }

        public func name(_ k: ItemKey) -> String {
            if case .module(let m) = k { return RowNameRule.clip(RowNameRule.moduleName(m)) }
            if let m = RowNameRule.appleModuleName(k) { return RowNameRule.clip(m) }
            guard let i = items[k] else { return RowNameRule.clip(RowNameRule.fallbackName(k)) }
            let app = appName(k, i)
            // A leftover heuristic key of an owner that has status keys is just the app (never numbered against them).
            if case .heuristic = k, let id = RowNameRule.ownerID(k), owners[id]?.contains(k) != true {
                return RowNameRule.clip(app.isEmpty ? RowNameRule.fallbackName(k) : app)
            }
            let group = RowNameRule.ownerID(k).flatMap { owners[$0] } ?? [k]
            if group.count <= 1 {
                if !app.isEmpty { return RowNameRule.clip(app) }
                let raw = detail(k)
                return raw.isEmpty ? RowNameRule.clip(RowNameRule.fallbackName(k)) : RowNameRule.clip(raw)
            }
            // Several items: a real label that no sibling shares, else "<app> (n)".
            let mine = label(k)
            if !mine.isEmpty, group.filter({ label($0) == mine }).count == 1 { return RowNameRule.clip(mine) }
            let base = app.isEmpty ? RowNameRule.fallbackName(k) : app
            let suffix = " (\((group.firstIndex(of: k) ?? 0) + 1))"
            return RowNameRule.clip(base, to: maxNameLength - suffix.count) + suffix
        }
    }

    /// Owner identity for counting items; nil for modules (each names itself).
    static func ownerID(_ k: ItemKey) -> String? {
        switch k {
        case .status(let o, let a): return appleModuleName(.status(ownerKey: o, autosaveName: a)) != nil ? nil : o
        case .heuristic(let b, _, _): return b
        case .module: return nil
        }
    }

    /// Apple's menu-extra hosts (exact owner ids, lowercased) -> the name an otherwise unnamed item of theirs reads as.
    static let appleAgents: [String: String] = [
        "com.apple.systemuiserver": "SystemUIServer", "com.apple.controlcenter": "Control Center", "com.apple.menubaragent": "MenuBarAgent",
    ]

    /// Last-resort row name for a key with no usable app name. Never blank: a heuristic key whose fingerprint has no letters or digits
    /// (" \n ##%") reads as the owner's last path component, and an Apple agent's orphan reads "SystemUIServer item".
    static func fallbackName(_ k: ItemKey) -> String {
        if case .heuristic(let b, let f, _) = k {
            if let agent = appleAgents[b.lowercased()] { return agent + " item" }
            let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains(where: { $0.isLetter || $0.isNumber }) { return t }
            let last = b.split(separator: ".").last.map(String.init) ?? b
            return last.isEmpty ? b : last
        }
        return ArrangeSections.fallbackTitle(k)
    }

    /// Time Machine and friends are status keys of Apple's agents named `com.apple.menuextra.<name>`: named like modules.
    static func appleModuleName(_ k: ItemKey) -> String? {
        guard case .status(let o, let a) = k else { return nil }
        let lo = o.lowercased()
        guard appleAgents[lo] != nil else { return nil }
        guard a.lowercased().hasPrefix("com.apple.menuextra."), a.split(separator: ".").count >= 4 else { return nil }
        return moduleName(a)
    }

    /// Context-free name of a lone item (no siblings known): the app name. Prefer a `Namer` wherever the layout is at hand.
    public static func soleName(_ i: ItemInfo) -> String { Namer(keys: [i.key], items: [i.key: i]).name(i.key) }
}
