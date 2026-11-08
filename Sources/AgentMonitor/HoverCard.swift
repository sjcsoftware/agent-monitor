import AgentMonitorCore
import AppKit

/// Fixed-width detail card (DESIGN §1.6). Text is drawn directly; the context bar is a layer so
/// its width can animate. The card is a pure function of its `CardModel`.
final class CardView: NSView {
    static let width: CGFloat = 314
    private static let inset: CGFloat = 1 // border
    private static let contentX: CGFloat = inset + 12
    private static let contentW: CGFloat = 288

    private struct Fonts {
        static let title = Theme.font(14, .bold)
        static let dir = Theme.font(12, .semibold)
        static let model = Theme.font(12, .semibold)
        static let effort = Theme.font(12, .medium)
        static let state = Theme.font(12, .bold)
        static let since = Theme.font(11, .semibold, tabular: true)
        static let caption = Theme.font(10, .bold)
        static let ctxValue = Theme.font(11, .semibold, tabular: true)
        static let number = Theme.font(15, .bold, tabular: true)
        static let hint = Theme.font(10, .medium)
    }

    /// Vertical layout, computed once from the type scale.
    private struct Layout {
        static let titleY: CGFloat = inset + 14
        static let titleH = Theme.lineHeight(Fonts.title)
        static let rowY = titleY + titleH + 9
        static let rowTextH = Theme.lineHeight(Fonts.dir)
        static let rowH = 7 + rowTextH + 7
        static let chipY = rowY + rowH + 4 + 12
        static let chipTextH = Theme.lineHeight(Fonts.state)
        static let chipH = 5 + chipTextH + 5
        static let ctxY = chipY + chipH + 12
        static let ctxRowH = max(Theme.lineHeight(Fonts.caption), Theme.lineHeight(Fonts.ctxValue))
        static let barY = ctxY + ctxRowH + 5
        static let barH: CGFloat = 6
        static let tilesY = barY + barH + 12
        static let numberH = Theme.lineHeight(Fonts.number)
        static let captionH = Theme.lineHeight(Fonts.caption)
        static let tileH = 7 + numberH + 1 + captionH + 7
        static let hintY = tilesY + tileH + 12
        static let height = hintY + Theme.lineHeight(Fonts.hint) + 10 + inset
    }

    static var height: CGFloat { Layout.height }

    private let track = CALayer()
    private let fill = CALayer()
    /// Draws an opaque background (for offscreen previews where there's no blur behind).
    var opaqueBackground = false
    /// Scales the card's background fill (1 = normal, 0 = clear); content is unaffected.
    var backgroundOpacity: CGFloat = 1 {
        didSet { if backgroundOpacity != oldValue { needsDisplay = true } }
    }

    var model: CardModel? {
        didSet {
            guard model != oldValue else { return }
            needsDisplay = true
            updateBar(animated: oldValue?.id == model?.id)
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        track.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        track.cornerRadius = Layout.barH / 2
        fill.cornerRadius = Layout.barH / 2
        fill.anchorPoint = .zero
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Theme.instantly {
            // Sublayers of a flipped view's backing layer share its flipped geometry.
            track.frame = CGRect(x: Self.contentX, y: Layout.barY, width: Self.contentW, height: Layout.barH)
        }
        updateBar(animated: false)
    }

    private func updateBar(animated: Bool) {
        guard let m = model else { return }
        let w = Self.contentW * CGFloat(m.ctxpct) / 100
        let apply = {
            self.fill.frame = CGRect(x: 0, y: 0, width: w, height: Layout.barH)
            self.fill.backgroundColor = Theme.contextFill(m.ctxlevel).cgColor
        }
        if animated { Theme.animate(apply) } else { Theme.instantly(apply) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model else { return }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        if opaqueBackground {
            Theme.hex(0x111A30, backgroundOpacity).setFill()
            card.fill()
        }
        Theme.cardFill.withAlphaComponent(Theme.cardFill.alphaComponent * backgroundOpacity).setFill()
        card.fill()
        Theme.cardBorder.setStroke()
        card.lineWidth = 1
        card.stroke()

        let x0 = Self.contentX, cw = Self.contentW
        let stateColor = Theme.state(m.state)

        // Title
        text(m.title, Fonts.title, Theme.text, in: NSRect(x: x0, y: Layout.titleY, width: cw, height: Layout.titleH), align: .center)

        // Where / what row
        let rowX = x0 + 12, rowW = cw - 24
        let textY = Layout.rowY + 7
        let model = NSMutableAttributedString(string: m.model.isEmpty ? "unknown" : m.model,
                                              attributes: [.font: Fonts.model, .foregroundColor: Theme.subtext])
        if !m.effort.isEmpty {
            model.append(NSAttributedString(string: " · ", attributes: [.font: Fonts.model, .foregroundColor: Theme.muted]))
            model.append(NSAttributedString(string: m.effort, attributes: [.font: Fonts.effort, .foregroundColor: Theme.subtext]))
        }
        let rightW = min(ceil(model.size().width) + 13 + 7, rowW * 0.6)
        let rightX = rowX + rowW - rightW
        icon("folder", Theme.accentHi, at: NSPoint(x: rowX, y: textY), lineHeight: Layout.rowTextH)
        text(m.proj, Fonts.dir, Theme.text, in: NSRect(x: rowX + 20, y: textY, width: max(0, rightX - 12 - rowX - 20), height: Layout.rowTextH))
        icon("cpu", Theme.accentHi, at: NSPoint(x: rightX, y: textY), lineHeight: Layout.rowTextH)
        draw(model, in: NSRect(x: rightX + 20, y: textY, width: rightW - 20, height: Layout.rowTextH))

        // State chip
        let chip = NSRect(x: x0, y: Layout.chipY, width: cw, height: Layout.chipH)
        (m.state == .ready ? NSColor(white: 1, alpha: 0.05) : stateColor.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8).fill()
        stateColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: chip.minX + 10, y: chip.midY - 4, width: 8, height: 8)).fill()
        let sinceText = "for \(m.since)"
        let sinceW = ceil(sinceText.size(withAttributes: [.font: Fonts.since]).width)
        let lineY = Layout.chipY + 5
        text(m.statetext, Fonts.state, stateColor,
             in: NSRect(x: chip.minX + 24, y: lineY, width: chip.width - 24 - 10 - sinceW - 8, height: Layout.chipTextH))
        text(sinceText, Fonts.since, Theme.subtext, in: NSRect(x: chip.maxX - 10 - sinceW, y: lineY + baselineShift(Fonts.state, Fonts.since), width: sinceW, height: Layout.chipTextH))

        // Context
        let capShift = baselineShift(Fonts.ctxValue, Fonts.caption)
        text("context", Fonts.caption, Theme.muted, in: NSRect(x: x0, y: Layout.ctxY + capShift, width: cw / 2, height: Layout.ctxRowH))
        text(m.contextText, Fonts.ctxValue, Theme.subtext, in: NSRect(x: x0 + cw / 2, y: Layout.ctxY, width: cw / 2, height: Layout.ctxRowH), align: .right)

        // Token tiles
        let tileW = (cw - 8) / 2
        tile(NSRect(x: x0, y: Layout.tilesY, width: tileW, height: Layout.tileH), symbol: "arrow.up", color: Theme.accentHi, number: m.tout, caption: "tokens written")
        tile(NSRect(x: x0 + tileW + 8, y: Layout.tilesY, width: tileW, height: Layout.tileH), symbol: "arrow.down", color: Theme.cyan, number: m.tin, caption: "tokens read")

        // Hint
        text("click to go to this window", Fonts.hint, Theme.muted, in: NSRect(x: x0, y: Layout.hintY, width: cw, height: Theme.lineHeight(Fonts.hint)), align: .center)
    }

    private func tile(_ r: NSRect, symbol: String, color: NSColor, number: String, caption: String) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.subtle.setFill()
        path.fill()
        Theme.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
        let y = r.minY + 7
        icon(symbol, color, at: NSPoint(x: r.minX + 10, y: y), lineHeight: Layout.numberH)
        text(number, Fonts.number, Theme.text, in: NSRect(x: r.minX + 10 + 13 + 5, y: y, width: r.width - 38, height: Layout.numberH))
        text(caption, Fonts.caption, Theme.muted, in: NSRect(x: r.minX + 10, y: y + Layout.numberH + 1, width: r.width - 20, height: Layout.captionH))
    }

    /// Offset that puts `small`'s baseline on `big`'s when both boxes start at the same y.
    private func baselineShift(_ big: NSFont, _ small: NSFont) -> CGFloat {
        (big.ascender - small.ascender).rounded()
    }

    private func icon(_ name: String, _ color: NSColor, at p: NSPoint, lineHeight: CGFloat) {
        guard let image = Theme.symbol(name, color: color, size: 11) else { return }
        let side: CGFloat = 13
        let s = image.size
        let scale = min(side / max(s.width, 1), side / max(s.height, 1), 1.2)
        let w = s.width * scale, h = s.height * scale
        image.draw(in: NSRect(x: p.x + (side - w) / 2, y: p.y + (lineHeight - h) / 2, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func text(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, align: NSTextAlignment = .left) {
        draw(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]), in: r, align: align)
    }

    private func draw(_ s: NSAttributedString, in r: NSRect, align: NSTextAlignment = .left) {
        guard r.width > 4 else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingTail
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        m.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Borderless, non-activating, click-through panel that hosts the card over a blurred backdrop.
final class CardController {
    private let panel: NSPanel
    private let cardView: CardView
    private let blur: NSVisualEffectView
    private(set) var shownId: String?
    private weak var anchor: PillView?

    init() {
        let size = NSSize(width: CardView.width, height: CardView.height)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.maskImage = Self.roundedMask(radius: 16)
        blur.autoresizingMask = [.width, .height]
        cardView = CardView(frame: root.bounds)
        cardView.autoresizingMask = [.width, .height]
        root.addSubview(blur)
        root.addSubview(cardView)
        panel.contentView = root
        setTransparency(Settings.transparency)
    }

    /// 0 = normal blurred background, 100 = fully clear (text, chips and tiles stay as they are).
    func setTransparency(_ value: Int) {
        let opacity = 1 - CGFloat(min(max(value, 0), 100)) / 100
        blur.alphaValue = opacity
        blur.isHidden = opacity == 0
        cardView.backgroundOpacity = opacity
    }

    func show(_ card: CardModel, anchor pill: PillView) {
        anchor = pill
        shownId = card.id
        cardView.model = card
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        shownId = nil
        anchor = nil
        panel.orderOut(nil)
    }

    func update(_ cards: [String: CardModel]) {
        guard let id = shownId else { return }
        guard let card = cards[id] else { return hide() }
        cardView.model = card
    }

    /// Top edge flush with the bottom of the menu bar (where app windows start), centred on the hovered
    /// icon, ≥ 8 px from screen edges.
    func reposition() {
        guard shownId != nil, let pill = anchor, let rect = pill.screenRect else { return }
        let screen = pill.window?.screen ?? NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let size = panel.frame.size
        var x = rect.midX - size.width / 2
        if let f = screen?.frame { x = min(max(x, f.minX + 8), f.maxX - 8 - size.width) }
        // visibleFrame.maxY is the menu bar's bottom; with an auto-hiding menu bar fall back to just below the icon.
        var top = rect.minY - 4
        if let visibleTop = screen?.visibleFrame.maxY, visibleTop < rect.minY { top = visibleTop }
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (top - size.height).rounded()))
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
