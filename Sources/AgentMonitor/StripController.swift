import AgentMonitorCore
import AppKit

/// One square icon pill per session (DESIGN §1.5).
final class PillView: NSView {
    let id: String
    let kind: AgentKind
    var onHover: ((PillView, Bool) -> Void)?
    var onClick: ((PillView) -> Void)?
    var onMenu: ((PillView, NSEvent) -> Void)?

    private let content = CALayer()
    private let bg = CALayer()
    private let icon = CAShapeLayer()
    private var size: CGFloat = 0
    private(set) var state: SessionState = .ready
    private var hovered = false

    init(id: String, kind: AgentKind, state: SessionState) {
        self.id = id
        self.kind = kind
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        icon.fillRule = AgentIcons.usesEvenOdd(kind) ? .evenOdd : .nonZero
        bg.borderWidth = 1
        content.addSublayer(bg)
        content.addSublayer(icon)
        layer?.addSublayer(content)
        Theme.instantly(applyColors)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSize(_ s: CGFloat) {
        guard s != size else { return }
        size = s
        let scale = s / 32
        let iconSize = min(16, (s - 8).rounded())
        Theme.instantly {
            content.frame = CGRect(x: 0, y: 0, width: s, height: s)
            bg.frame = content.bounds
            bg.cornerRadius = 11 * scale
            icon.path = AgentIcons.path(kind, size: iconSize)
            icon.frame = CGRect(x: ((s - iconSize) / 2).rounded(), y: ((s - iconSize) / 2).rounded(), width: iconSize, height: iconSize)
        }
    }

    func setState(_ s: SessionState) {
        guard s != state else { return }
        state = s
        Theme.animate(applyColors)
    }

    private func applyColors() {
        let color = Theme.state(state)
        icon.fillColor = color.cgColor
        if hovered {
            bg.backgroundColor = Theme.surface.withAlphaComponent(0.6).cgColor
            bg.borderColor = Theme.accent.withAlphaComponent(0.22).cgColor
        } else {
            bg.backgroundColor = Theme.base.withAlphaComponent(0.38).cgColor
            bg.borderColor = state == .ready ? NSColor(white: 1, alpha: 0.06).cgColor : color.withAlphaComponent(0.20).cgColor
        }
    }

    func animateIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.6
        scale.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = Theme.appearDuration
        group.timingFunction = Theme.easing
        content.add(group, forKey: "appear")
    }

    func animateOut(completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.appearDuration)
        CATransaction.setAnimationTimingFunction(Theme.easing)
        CATransaction.setCompletionBlock(completion)
        content.opacity = 0
        content.transform = CATransform3DMakeScale(0.6, 0.6, 1)
        CATransaction.commit()
    }

    func restore() {
        Theme.animate(duration: Theme.appearDuration) {
            content.opacity = 1
            content.transform = CATransform3DIdentity
        }
    }

    /// Slides from a horizontal offset back to the pill's laid-out position.
    func slide(from dx: CGFloat) {
        guard abs(dx) > 0.5 else { return }
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = dx
        a.toValue = 0
        a.duration = Theme.colorDuration
        a.timingFunction = Theme.easing
        content.add(a, forKey: "slide")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        Theme.animate(applyColors)
        onHover?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        Theme.animate(applyColors)
        onHover?(self, false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(self, event); return }
        onClick?(self)
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(self, event) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Screen rectangle, used to anchor the hover card.
    var screenRect: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

/// The menu-bar strip: a single status item whose width tracks the number of sessions.
/// Pills are only created/removed when the id list changes, so an open hover card survives updates.
final class StripController {
    var onHover: ((String, PillView, Bool) -> Void)?
    var onClick: ((String) -> Void)?
    var onMenu: ((PillView, NSEvent) -> Void)?
    var onLayout: (() -> Void)?

    private let item: NSStatusItem
    private let container = NSView()
    private var pills: [String: PillView] = [:]
    private var slots: [String] = []
    private var leaving = Set<String>()
    private var width: CGFloat = 0

    private var pillSize: CGFloat { min(32, max(18, NSStatusBar.system.thickness - 2)) }
    private var gap: CGFloat { max(4, (6 * pillSize / 32).rounded()) }
    private let edge: CGFloat = 2

    init() {
        item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = "AgentMonitorStrip"
        item.behavior = []
        item.isVisible = false
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.setAccessibilityLabel("Agent Monitor")
            container.frame = button.bounds
            container.autoresizingMask = [.width, .height]
            button.addSubview(container)
        }
    }

    func pill(_ id: String) -> PillView? { pills[id] }

    func setIds(_ ids: [String], cards: [String: CardModel]) {
        let incoming = Set(ids)
        // Leaving pills keep their slot until their fade-out finishes.
        for id in slots where !incoming.contains(id) && !leaving.contains(id) {
            guard let pill = pills[id] else { continue }
            leaving.insert(id)
            pill.animateOut { [weak self] in
                guard let self, self.leaving.remove(id) != nil else { return }
                self.pills[id]?.removeFromSuperview()
                self.pills[id] = nil
                self.slots.removeAll { $0 == id }
                self.relayout()
            }
        }
        var merged = ids
        for (index, id) in slots.enumerated() where leaving.contains(id) && !incoming.contains(id) {
            merged.insert(id, at: min(index, merged.count))
        }
        var fresh: [PillView] = []
        for id in ids where leaving.remove(id) != nil { pills[id]?.restore() }
        for id in ids where pills[id] == nil {
            guard let card = cards[id] else { continue }
            let pill = PillView(id: id, kind: card.kind, state: card.state)
            pill.onHover = { [weak self] p, inside in self?.onHover?(p.id, p, inside) }
            pill.onClick = { [weak self] p in self?.onClick?(p.id) }
            pill.onMenu = { [weak self] p, e in self?.onMenu?(p, e) }
            pills[id] = pill
            container.addSubview(pill)
            fresh.append(pill)
        }
        slots = merged.filter { pills[$0] != nil }
        relayout()
        fresh.forEach { $0.animateIn() }
    }

    func update(_ cards: [String: CardModel]) {
        for (id, card) in cards { pills[id]?.setState(card.state) }
    }

    private func relayout() {
        let size = pillSize
        let oldWidth = width
        let oldX = pills.mapValues { $0.frame.minX }
        let count = CGFloat(slots.count)
        width = slots.isEmpty ? 0 : count * size + (count - 1) * gap + edge * 2
        item.length = width
        item.isVisible = !slots.isEmpty
        let height = item.button?.bounds.height ?? NSStatusBar.system.thickness
        container.frame = NSRect(x: 0, y: 0, width: width, height: height)
        for (i, id) in slots.enumerated() {
            guard let pill = pills[id] else { continue }
            let x = edge + CGFloat(i) * (size + gap)
            pill.setSize(size)
            pill.frame = NSRect(x: x, y: ((height - size) / 2).rounded(), width: size, height: size)
            // Status items are right-anchored, so on-screen movement = change in distance from the right edge.
            if let previous = oldX[id], oldWidth > 0 {
                pill.slide(from: (width - x) - (oldWidth - previous))
            }
        }
        onLayout?()
    }
}
