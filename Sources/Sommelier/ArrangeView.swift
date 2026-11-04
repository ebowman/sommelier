import AppKit
import SwiftUI
import SommelierCore

@MainActor
final class ArrangeWindowController: NSObject, NSWindowDelegate {
    let viewModel: ArrangeViewModel
    private var window: NSWindow?

    init(model: AppModel) {
        viewModel = ArrangeViewModel(model: model)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Single instance: reopening brings the existing window to the front.
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Arrange"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 560, height: 420)
            w.contentView = NSHostingView(rootView: ArrangeView(vm: viewModel))
            w.delegate = self
            if !w.setFrameUsingName("Arrange") { w.center() }
            w.setFrameAutosaveName("Arrange")
            window = w
        }
        viewModel.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { viewModel.stop() }
}

struct ArrangeView: View {
    @Bindable var vm: ArrangeViewModel

    var body: some View {
        let content = vm.content
        VStack(spacing: 0) {
            toolbar(content)
            if vm.isPaused {
                banner("Bartender is running; Sommelier is paused and will not touch the menu bar.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StripView(vm: vm, strip: content.visible, title: "Visible", subtitle: "The real menu bar, left to right")
                    StripView(vm: vm, strip: content.hidden, title: "Hidden", subtitle: "Shown on demand in the overflow panel")
                    StripView(vm: vm, strip: content.alwaysHidden, title: "Always hidden", subtitle: "Never shown")
                }
                .padding(14)
            }
            Divider()
            HStack {
                Text(vm.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                if let m = vm.message { Text("· " + m).font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 560, minHeight: 420)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { vm.confirm != nil }, set: { if !$0 { vm.confirm = nil } }), presenting: vm.confirm) { c in
            Button(confirmButton(c)) { vm.confirmed(c) }
            Button("Cancel", role: .cancel) { vm.confirm = nil }
        } message: { c in
            Text(confirmText(c))
        }
    }

    private func toolbar(_ content: ArrangeContent) -> some View {
        HStack(spacing: 8) {
            Button("Re-apply layout") { vm.reapply() }
                .help("Run one reconcile pass now (also retries failed items)")
            Button("Adopt current order…") { vm.askAdopt() }
                .help("Rebuild the layout from the menu bar as it is now")
            Button("Hide what does not fit…") { vm.askHideNotFitting() }
                .disabled(!vm.hasNotFitting)
                .help(vm.hasNotFitting ? "Move the items macOS pushed behind its chevron into Hidden" : "Nothing is behind the chevron")
            Spacer()
            TextField("Filter", text: $vm.filter).textFieldStyle(.roundedBorder).frame(width: 180)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(8).background(Color.orange.opacity(0.18))
    }

    private var confirmTitle: String {
        switch vm.confirm { case .adopt?: "Adopt the current menu bar order?"; case .hideNotFitting?: "Hide what does not fit?"; case nil: "" }
    }
    private func confirmButton(_ c: ArrangeViewModel.Confirm) -> String {
        switch c { case .adopt: "Adopt"; case .hideNotFitting: "Hide" }
    }
    private func confirmText(_ c: ArrangeViewModel.Confirm) -> String {
        switch c {
        case .adopt:
            return "Visible becomes exactly the bar as drawn now and Hidden the items currently off the bar (Always hidden is kept). Your current order is replaced."
        case .hideNotFitting(_, let titles, let blocked):
            var t = titles.isEmpty ? "Nothing can be hidden." : "These will move to Hidden (an app's items hide together): " + titles.joined(separator: ", ") + "."
            if !blocked.isEmpty { t += " Cannot be hidden and stay: " + blocked.joined(separator: ", ") + "." }
            return t
        }
    }
}

struct StripView: View {
    @Bindable var vm: ArrangeViewModel
    let strip: ArrangeStrip
    let title: String
    let subtitle: String
    @State private var endTargeted = false
    @State private var showNotRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(strip.rows.filter { !$0.isBoundary && !$0.isGhost }.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            // Left to right, wrapping onto further lines when the window is narrower than the bar (the order stays reading order).
            FlowLayout(lineSpacing: 4) {
                ForEach(Array(strip.rows.enumerated()), id: \.element.id) { i, r in
                    DropGap(vm: vm, section: strip.section, slot: i)
                    if r.isBoundary { BoundaryLine() } else { CapsuleSlot(vm: vm, row: r, section: strip.section, slot: i) }
                }
                DropGap(vm: vm, section: strip.section, slot: strip.rows.count)
                if strip.rows.isEmpty {
                    Text(vm.isFiltering ? "No match" : "Drop items here").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(endTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
            .dropDestination(for: ArrangePayload.self, action: { items, _ in
                vm.drop(items, section: strip.section, slot: strip.rows.count)
            }, isTargeted: { endTargeted = $0 })
            if !strip.notRunning.isEmpty {
                DisclosureGroup("Not running (\(strip.notRunning.count))", isExpanded: $showNotRunning) {
                    FlowLayout(lineSpacing: 4) {
                        ForEach(strip.notRunning, id: \.id) { CapsuleSlot(vm: vm, row: $0, section: strip.section, slot: nil) }
                    }
                    .padding(.vertical, 4)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Insertion point between two capsules; draws the indicator while a drag hovers it.
struct DropGap: View {
    @Bindable var vm: ArrangeViewModel
    let section: LayoutSection
    let slot: Int
    @State private var targeted = false

    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(width: targeted ? 14 : 8, height: 34)
            .overlay(Capsule().fill(Color.accentColor).frame(width: 3, height: 30).opacity(targeted ? 1 : 0))
            .contentShape(Rectangle())
            .dropDestination(for: ArrangePayload.self, action: { items, _ in
                vm.drop(items, section: section, slot: slot)
            }, isTargeted: { targeted = $0 })
    }
}

struct BoundaryLine: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 2, height: 26)
            Text("overflow").font(.system(size: 8)).foregroundStyle(.orange)
        }
        .padding(.horizontal, 2)
        .help("macOS overflow boundary: items to the left are on the bar per the system but not drawn (they do not fit)")
    }
}

/// One capsule plus its drag/drop/menu behaviour. Dropping on a capsule inserts before or after it, by half.
struct CapsuleSlot: View {
    @Bindable var vm: ArrangeViewModel
    let row: ArrangeRow
    let section: LayoutSection
    /// Position in the strip's row list; nil for the not-running group (no drop target).
    let slot: Int?
    @State private var width: CGFloat = 60

    var body: some View {
        let cap = CapsuleView(row: row, grouped: false)
        let interactive = vm.filter.isEmpty && !row.isGhost
        Group {
            if row.draggable && interactive {
                cap.draggable(ArrangePayload(storeKey: row.key.description))
            } else {
                cap
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .dropDestination(for: ArrangePayload.self, action: { items, loc in
            guard let slot else { return false }
            return vm.drop(items, section: section, slot: loc.x < width / 2 ? slot : slot + 1)
        })
        .contextMenu { if !row.isAnchor && !row.isGhost { menu } }
    }

    @ViewBuilder private var menu: some View {
        Button("Move to Visible") { vm.move(row.key, to: .visible) }.disabled(!vm.canMove(row.key, to: .visible))
        Button("Move to Hidden") { vm.move(row.key, to: .hidden) }.disabled(!vm.canMove(row.key, to: .hidden))
        Button("Move to Always hidden") { vm.move(row.key, to: .alwaysHidden) }.disabled(!vm.canMove(row.key, to: .alwaysHidden))
        if section == .visible {
            Divider()
            Button("Move left") { vm.step(row.key, .left) }.disabled(!vm.canStep(row.key, .left))
            Button("Move right") { vm.step(row.key, .right) }.disabled(!vm.canStep(row.key, .right))
        }
        if case .failed = row.badge {
            Divider()
            Button("Retry") { vm.retry(row.key) }
        }
        if section != .visible {
            Divider()
            Button("Reveal in menu bar") { vm.reveal() }
        }
    }
}

struct CapsuleView: View {
    let row: ArrangeRow
    let grouped: Bool

    var body: some View {
        HStack(spacing: 5) {
            ArrangeIcon(row: row).frame(width: 18, height: 18)
            Text(row.title).font(.system(size: 12)).lineLimit(1)
            BadgeView(badge: row.badge)
            if let n = row.capabilityNote {
                Image(systemName: "nosign").font(.system(size: 9)).foregroundStyle(.secondary).help(n)
            }
            if !row.unitMates.isEmpty {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(Capsule().fill(row.isGhost ? Color.accentColor.opacity(0.10) : Color.primary.opacity(row.isAnchor ? 0.04 : 0.10)))
        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: row.isGhost ? [3, 2] : [])).foregroundStyle(
            row.notFitting ? Color.orange : row.unitMates.isEmpty ? Color.clear : Color.accentColor.opacity(0.5)))
        .opacity(row.isAnchor ? 0.55 : row.isGhost ? 0.75 : row.notFitting ? 0.7 : 1)
        .padding(.horizontal, 2)
        .help(tooltip)
    }

    private var tooltip: String {
        var parts = [row.title]
        if let u = row.unitTooltip { parts.append(u) }
        if row.isGhost { parts.append("Waiting for the menu bar: this is where it is going, not where it is.") }
        if row.notFitting { parts.append(ArrangeBadge.notFitting.tooltip) }
        if row.badge != .none { parts.append(row.badge.tooltip) }
        if let n = row.capabilityNote { parts.append(n) }
        if row.notRunning { parts.append("The app is not running.") }
        return parts.joined(separator: "\n")
    }
}

struct BadgeView: View {
    let badge: ArrangeBadge
    var body: some View {
        switch badge {
        case .none: EmptyView()
        case .inPlace: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11)).help(badge.tooltip)
        case .moving: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.system(size: 11)).help(badge.tooltip)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 11)).help(badge.tooltip)
        case .cannotChange: Image(systemName: "nosign").foregroundStyle(.secondary).font(.system(size: 11)).help(badge.tooltip)
        case .notFitting: Image(systemName: "chevron.left.2").foregroundStyle(.orange).font(.system(size: 11)).help(badge.tooltip)
        }
    }
}

struct ArrangeIcon: View {
    let row: ArrangeRow
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let img = Self.image(for: row) { Image(nsImage: img).resizable().interpolation(.high) }
        else { Image(systemName: row.isAnchor ? "switch.2" : "menubar.rectangle").resizable().scaledToFit().foregroundStyle(.secondary).padding(1) }
    }

    @MainActor static func image(for row: ArrangeRow) -> NSImage? {
        let ws = NSWorkspace.shared
        if let pid = row.ownerPID, let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path {
            return cached(path) { ws.icon(forFile: path) }
        }
        if let id = row.ownerBundleID, let url = ws.urlForApplication(withBundleIdentifier: id) {
            return cached(url.path) { ws.icon(forFile: url.path) }
        }
        return nil
    }

    @MainActor private static func cached(_ k: String, _ make: () -> NSImage) -> NSImage {
        if let i = cache[k] { return i }
        let i = make(); cache[k] = i; return i
    }
}

/// Wraps children onto new lines at the proposed width.
struct FlowLayout: SwiftUI.Layout {
    var lineSpacing: CGFloat = 4

    private func lines(_ subviews: SwiftUI.LayoutSubviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            frames.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width; lineH = max(lineH, s.height); maxW = max(maxW, x)
        }
        return (frames, CGSize(width: maxW, height: y + lineH))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout ()) -> CGSize {
        let r = lines(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? r.size.width, height: r.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout ()) {
        let r = lines(subviews, width: bounds.width)
        for (v, f) in zip(subviews, r.frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}
