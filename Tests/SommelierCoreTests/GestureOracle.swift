import Foundation
@testable import SommelierCore

/// sommelier-ejb.32: the PRE-Lean, pure-Swift gesture implementation (gdu.149 semantics, commit d7f0826), kept ONLY here as the oracle of the differential test
/// (`GestureDifferentialTests`). The app computes gestures with the proved Lean core (`Layout.applying`); this copy exists so that a difference between the two is a test failure.
extension Layout {
    private mutating func oracleSet(_ keys: [ItemKey], in section: LayoutSection) {
        switch section {
        case .visible: visible = keys
        case .hidden: hidden = keys
        case .alwaysHidden: alwaysHidden = keys
        }
    }

    private mutating func oracleInsert(_ group: [ItemKey], into section: LayoutSection, at index: Int?) {
        var ks = keys(in: section)
        let i: Int
        if let index {
            i = max(0, min(index, ks.count))
        } else if section == .visible {
            var start = ks.count
            while start > 0, case .module = ks[start - 1] { start -= 1 }
            i = start
        } else {
            i = ks.count
        }
        ks.insert(contentsOf: group, at: i)
        oracleSet(ks, in: section)
    }

    @discardableResult
    mutating func oracleMove(_ key: ItemKey, to section: LayoutSection, index: Int? = nil, units: HideUnitRule = .ownerKeys) -> [ItemKey] {
        if self.section(of: key) == section {
            remove(key)
            oracleInsert([key], into: section, at: index)
            return [key]
        }
        let unit = units.unit(of: key)
        let siblings = allKeys.filter { $0 != key && units.unit(of: $0) == unit }
        let group = [key] + siblings
        for k in group { remove(k) }
        oracleInsert(group, into: section, at: index)
        return group
    }

    @discardableResult
    mutating func oracleHideNotFitting(_ keys: [ItemKey], units: HideUnitRule = .ownerKeys) -> [ItemKey] {
        var moved: [ItemKey] = []
        for k in keys {
            guard let s = section(of: k), s == .visible else { continue }
            for m in oracleMove(k, to: .hidden, units: units) where !moved.contains(m) { moved.append(m) }
        }
        return moved
    }
}
