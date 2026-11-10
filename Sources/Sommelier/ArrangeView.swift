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
            viewModel.onWindowCommand = { [weak self] cmd in self?.apply(cmd) }
            viewModel.windowProbe = { [weak self] in
                guard let w = self?.window else { return (false, false, false) }
                return (w.isVisible && !w.isMiniaturized, w.isVisible && w.occlusionState.contains(.visible), w.isKeyWindow)
            }
        }
        viewModel.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// gdu.100: float during an engine action so the activated menu-bar app cannot cover the window; take activation back after.
    private func apply(_ cmd: ArrangeWindowGuard.Command) {
        guard let w = window else { return }
        switch cmd {
        case .float:
            AppLog.log(.arrange, "arrange window: float")
            w.level = .floating
        case .restore(let orderFront, let reactivate):
            AppLog.log(.arrange, "arrange window: restore(orderFront: \(orderFront), reactivate: \(reactivate))")
            w.level = .normal
            // gdu.136: the window ends the action at least as visible as it began it: in front of the app the drag activated.
            if orderFront, w.isVisible, !w.isMiniaturized { w.orderFrontRegardless() }
            if reactivate {
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func windowWillClose(_ notification: Notification) { viewModel.stop() }
}

struct ArrangeView: View {
    @Bindable var vm: ArrangeViewModel

    var body: some View {
        let _ = vm.renderCount += 1   // gdu.117: idle-render counter (logged by the tick)
        let content = vm.content
        VStack(spacing: 0) {
            toolbar(content)
            if vm.isPaused {
                banner("Bartender is running; Sommelier is paused and will not touch the menu bar.")
            }
            if vm.controlCenterDataDenied {
                HStack {
                    Text("macOS denies Sommelier access to Control Center's hidden-item list; it cannot tell hidden items from visible ones and will not act.")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("Fix…") { vm.showPermissions() }
                }
                .padding(8).background(Color.orange.opacity(0.18))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StripView(vm: vm, strip: content.visible, placeholder: content.visiblePlaceholder, title: "Visible", subtitle: "Your order, left to right; each badge says where the real menu bar stands")
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
        .sheet(item: $vm.barOrderSheet) { sheet in
            BarOrderSheetView(sheet: sheet, save: { vm.saveBarOrder(sheet) }, cancel: { vm.barOrderSheet = nil })
        }
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
            Button("Use the bar's current order…") { vm.askUseBarOrder() }
                .disabled(vm.barOrderPreview == nil)
                .help(vm.barOrderPreview == nil ? "Available when the bar is read and differs from your order" : "Save the order the menu bar has now as your order, without moving anything")
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
        switch vm.confirm { case .hideNotFitting?: "Hide what does not fit?"; case nil: "" }
    }
    private func confirmButton(_ c: ArrangeViewModel.Confirm) -> String {
        switch c { case .hideNotFitting: "Hide" }
    }
    private func confirmText(_ c: ArrangeViewModel.Confirm) -> String {
        switch c {
        case .hideNotFitting(_, let titles, let blocked, _):
            var t = titles.isEmpty ? "Nothing can be hidden." : "These will move to Hidden (an app's items hide together): " + titles.joined(separator: ", ") + "."
            if !blocked.isEmpty { t += " Cannot be hidden and stay: " + blocked.joined(separator: ", ") + "." }
            return t
        }
    }
}

/// ejb.9: lists what "Use the bar's current order" changes (before -> after position in Visible) and asks Save / Cancel. Saving moves nothing:
/// the new order is the one the bar already has.
struct BarOrderSheetView: View {
    let sheet: ArrangeViewModel.BarOrderSheet
    let save: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use the bar's current order?").font(.headline)
            Text("Your order in Visible becomes the order the menu bar has now. Nothing is moved: the bar already looks like this. Items that are not on the bar keep their places. These items change place (position in Visible, from left):")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(sheet.lines.enumerated()), id: \.offset) { _, line in Text(line).font(.system(size: 12)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 260)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 440)
    }
}

struct StripView: View {
    @Bindable var vm: ArrangeViewModel
    let strip: ArrangeStrip
    var placeholder: String?
    let title: String
    let subtitle: String
    var hint: String? = nil
    @State private var endTargeted = false
    @State private var showNotRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(strip.rows.filter { !$0.isBoundary && !$0.isGhost }.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary) }
            // Left to right, wrapping onto further lines when the window is narrower than the bar (the order stays reading order).
            FlowLayout(lineSpacing: 4) {
                if let placeholder {
                    // No trustworthy observation: never draw the layout as "the real menu bar", and no drop targets.
                    Text(placeholder).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 8)
                }
                ForEach(Array((placeholder == nil ? strip.rows : []).enumerated()), id: \.element.id) { i, r in
                    DropGap(vm: vm, section: strip.section, slot: i)
                    if r.isBoundary { BoundaryLine() } else { CapsuleSlot(vm: vm, row: r, rows: strip.rows, section: strip.section, slot: i) }
                }
                if placeholder == nil { DropGap(vm: vm, section: strip.section, slot: strip.rows.count) }
                if strip.rows.isEmpty, placeholder == nil {
                    Text(vm.isFiltering ? "No match" : "Drop items here").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(endTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
            .dropDestination(for: ArrangePayload.self, action: { items, _ in
                vm.drop(items, section: strip.section, slot: strip.rows.count)
            }, isTargeted: { endTargeted = $0; vm.dragTargeting("end-\(strip.section.rawValue)", $0) })
            if !strip.notRunning.isEmpty {
                DisclosureGroup("Not running (\(strip.notRunning.count))", isExpanded: $showNotRunning) {
                    FlowLayout(lineSpacing: 4) {
                        ForEach(strip.notRunning, id: \.id) { CapsuleSlot(vm: vm, row: $0, rows: strip.rows, section: strip.section, slot: nil) }
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
            }, isTargeted: { targeted = $0; vm.dragTargeting("gap-\(section.rawValue)-\(slot)", $0) })
    }
}

struct BoundaryLine: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 2, height: 26)
            Text("overflow").font(.system(size: 8)).foregroundStyle(.orange)
        }
        .padding(.horizontal, 2)
        .help("Fold line: items to the left of it are behind macOS's « chevron (the bar is full); items to the right are drawn")
    }
}

/// One capsule plus its drag/drop/menu behaviour. Dropping on a capsule inserts before or after it, by half.
struct CapsuleSlot: View {
    @Bindable var vm: ArrangeViewModel
    let row: ArrangeRow
    /// The strip's rows, already built for this render: the step menu items judge on these instead of rebuilding `content` (gdu.93).
    let rows: [ArrangeRow]
    let section: LayoutSection
    /// Position in the strip's row list; nil for the not-running group (no drop target).
    let slot: Int?
    @State private var width: CGFloat = 60
    @State private var shakeCount = 0

    var body: some View {
        let cap = CapsuleView(row: row, grouped: false)
        // gdu.116: the modifier chain is the same for every row in every state. `.draggable` is always attached; a row that cannot be
        // picked up is refused at drop time (ArrangeDrop.sourceRefusal, ArrangeViewModel.drop). Swapping `cap.draggable` for `cap`
        // when `draggable`/the filter changed destroyed the view that owned a running drag session.
        cap.draggable(ArrangePayload(storeKey: row.key.description, fromGhost: row.isGhost))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .dropDestination(for: ArrangePayload.self, action: { items, loc in
            guard let slot else { return false }
            return vm.drop(items, section: section, slot: loc.x < width / 2 ? slot : slot + 1)
        }, isTargeted: { vm.dragTargeting("row-\(row.key.description)", $0) })
        .contextMenu { if !row.isAnchor && (!row.isGhost || ArrangeMenuRules.ghostInteractive(row)) { menu } }
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakeCount) { content, dx in
            content.offset(x: dx)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-6, duration: 0.05); LinearKeyframe(6, duration: 0.05); LinearKeyframe(-4, duration: 0.05)
                LinearKeyframe(4, duration: 0.05); LinearKeyframe(0, duration: 0.05)
            }
        }
        .overlay(alignment: .top) {
            if let r = vm.refusal, r.key == row.key, !row.isGhost || ArrangeMenuRules.ghostInteractive(row) {
                CalloutBubble(text: r.text).alignmentGuide(.top) { d in d[.bottom] + 6 }.allowsHitTesting(false).transition(.opacity)
            }
        }
        .zIndex(vm.refusal?.key == row.key ? 10 : 0)
        .onChange(of: vm.refusal) { _, new in if let new, new.key == row.key { shakeCount += 1 } }
        .animation(.easeOut(duration: 0.15), value: vm.refusal)
    }

    @ViewBuilder private var menu: some View {
        Button("Move to Visible") { vm.move(row.key, to: .visible) }.disabled(!row.movableTo.contains(.visible))
        Button("Move to Hidden") { vm.move(row.key, to: .hidden) }.disabled(!row.movableTo.contains(.hidden))
        Button("Move to Always hidden") { vm.move(row.key, to: .alwaysHidden) }.disabled(!row.movableTo.contains(.alwaysHidden))
        if let why = ArrangeMenuRules.whyText(row) {
            Divider()
            Button(why) {}.disabled(true)
        }
        if section == .visible && ArrangeMenuRules.showsStepItems() {
            Divider()
            Button("Move left") { vm.step(row.key, .left) }.disabled(!row.canStepLeft)
            Button("Move right") { vm.step(row.key, .right) }.disabled(!row.canStepRight)
        }
        if ArrangeMenuRules.showsTryAgain(row) {
            Divider()
            Button("Try again") { vm.retry(row.key) }
        }
        if section == .hidden {
            Divider()
            Button("Reveal in menu bar") { vm.reveal() }
        } else if section == .alwaysHidden {
            Divider()
            Button("Reveal in menu bar (Always hidden items stay hidden)") {}.disabled(true)
        }
    }
}

struct CalloutBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(minWidth: 240, maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 3))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange, lineWidth: 1))
    }
}

struct CapsuleView: View {
    let row: ArrangeRow
    let grouped: Bool

    var body: some View {
        HStack(spacing: 5) {
            ArrangeIcon(row: row).frame(width: 18, height: 18)
            Text(row.title).font(.system(size: 12)).lineLimit(1)
            BadgeView(badge: row.badge, movingHelp: row.moveReason)
            if let n = row.capabilityNote {
                Image(systemName: "nosign").font(.system(size: 9)).foregroundStyle(.secondary).help(row.capabilityTooltip ?? n)
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
        if !row.detail.isEmpty, row.detail != row.title { parts.append(row.detail) }
        if let u = row.unitTooltip { parts.append(u) }
        if row.isGhost { parts.append("Waiting for the menu bar: this is where it is going, not where it is.") }
        if row.notFitting { parts.append(ArrangeBadge.notFitting.tooltip) }
        if row.badge != .none { parts.append(row.badgeTooltip) }
        else if let why = ArrangeMenuRules.whyText(row) { parts.append(why) }
        if let n = row.capabilityTooltip { parts.append(n) }
        if row.notRunning { parts.append("The app is not running.") }
        return parts.joined(separator: "\n")
    }
}

struct BadgeView: View {
    let badge: ArrangeBadge
    var movingHelp: String? = nil
    var body: some View {
        switch badge {
        case .none: EmptyView()
        case .inPlace: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11)).help(badge.tooltip)
        case .inPlacePending:
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(0.55)).font(.system(size: 11))
                Circle().fill(.orange).frame(width: 4, height: 4)
            }.help(badge.tooltip)
        case .moving: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.system(size: 11)).help(movingHelp ?? badge.tooltip)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 11)).help(badge.tooltip)
        case .cannotChange: Image(systemName: "nosign").foregroundStyle(.secondary).font(.system(size: 11)).help(badge.tooltip)
        case .notFitting: Image(systemName: "chevron.left.2").foregroundStyle(.orange).font(.system(size: 11)).help(badge.tooltip)
        case .waitingForPosition: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.system(size: 11)).help(badge.tooltip)
        case .ghost: Image(systemName: "circle.dashed").foregroundStyle(.secondary).font(.system(size: 11)).help(badge.tooltip)
        case .cannotPlace: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 11)).help(badge.tooltip)
        case .behindChevron: Text("«").foregroundStyle(.orange).font(.system(size: 12, weight: .bold)).help(badge.tooltip)
        case .unreadAfterHandDrag: Image(systemName: "hourglass").foregroundStyle(.orange).font(.system(size: 11)).help(badge.tooltip)
        case .stale: Text("~").foregroundStyle(.orange).font(.system(size: 11, weight: .bold)).help(badge.tooltip)
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
