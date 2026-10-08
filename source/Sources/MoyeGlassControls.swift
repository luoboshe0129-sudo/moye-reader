import AppKit
import QuartzCore

/// Draw the icon and title as one centered group, with padding inside the glass.
private final class MoyeGlassButtonCell: NSButtonCell {
    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        guard let button = view as? NSButton else { return }
        let foreground = (button.contentTintColor ?? .labelColor).withAlphaComponent(button.isEnabled ? 1 : 0.42)
        let attributes: [NSAttributedString.Key: Any] = [.font: button.font ?? NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: foreground]
        let title = button.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let text = NSAttributedString(string: title, attributes: attributes)
        let showImage = button.image != nil && button.imagePosition != .noImage
        let showText = !title.isEmpty && button.imagePosition != .imageOnly
        let iconSize: CGFloat = min(19, max(14, frame.height - 16))
        let gap: CGFloat = showImage && showText ? 8 : 0
        let padding: CGFloat = frame.width < 58 ? 6 : (frame.width < 100 ? 12 : 15)
        let iconWidth: CGFloat = showImage ? iconSize : 0
        let availableText = max(0, frame.width - padding * 2 - iconWidth - gap)
        let textWidth = showText ? min(text.size().width, availableText) : 0
        let groupWidth = iconWidth + gap + textWidth
        var x = button.alignment == .left ? frame.minX + padding : frame.midX - groupWidth / 2
        if showImage, let original = button.image {
            let image = original.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [foreground])) ?? original
            image.draw(in: NSRect(x: x, y: frame.midY - iconSize / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: button.isEnabled ? 1 : 0.45, respectFlipped: true, hints: nil)
            x += iconSize + gap
        }
        if showText {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var drawing = attributes
            drawing[.paragraphStyle] = style
            let height = text.size().height
            (title as NSString).draw(in: NSRect(x: x, y: frame.midY - height / 2, width: textWidth, height: height + 1), withAttributes: drawing)
        }
    }

    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        (controlView as? MoyeGlassButton)?.setPressed(flag)
    }
}

final class MoyeGlassButton: NSButton {
    private let sheen = CAGradientLayer()
    private var hoverArea: NSTrackingArea?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let glassCell = MoyeGlassButtonCell(textCell: "")
        glassCell.setButtonType(.momentaryPushIn)
        cell = glassCell
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 14, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = surfaceTint(0.48).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = borderTint(0.8).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowOpacity = 0.08
        sheen.colors = [NSColor.white.withAlphaComponent(0.45).cgColor, NSColor.white.withAlphaComponent(0.04).cgColor, NSColor.white.withAlphaComponent(0.12).cgColor]
        sheen.locations = [0, 0.55, 1]
        sheen.opacity = 0.12
        sheen.cornerRadius = 14
        layer?.addSublayer(sheen)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sheen.frame = bounds
        sheen.cornerRadius = layer?.cornerRadius ?? 14
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; animateSurface(pressed: false) }
    override func mouseExited(with event: NSEvent) { hovering = false; animateSurface(pressed: false) }

    fileprivate func setPressed(_ pressed: Bool) { animateSurface(pressed: pressed) }

    private func animateSurface(pressed: Bool) {
        guard isEnabled, let layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let current = layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
        let scale: CGFloat = pressed && !reduceMotion ? 0.96 : 1
        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = current; animation.toValue = scale
        animation.mass = 0.7; animation.stiffness = 380; animation.damping = 26
        animation.duration = reduceMotion ? 0 : (pressed ? 0.12 : 0.32)
        layer.add(animation, forKey: "glass-press")
        CATransaction.begin(); CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.16)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        sheen.opacity = pressed ? 0.6 : (hovering ? 0.3 : 0.12)
        layer.shadowOpacity = pressed ? 0.02 : (hovering ? 0.18 : 0.08)
        CATransaction.commit()
    }
}

final class MoyeSearchBar: NSVisualEffectView {
    private let glow = CAGradientLayer()
    private var focused = false
    private var busy = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 25
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = surfaceTint(0.64).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = borderTint(0.9).cgColor
        glow.colors = [NSColor.clear.cgColor, NSColor(calibratedRed: 0.66, green: 0.55, blue: 0.96, alpha: 0.25).cgColor, NSColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 0.5)
        glow.opacity = 0
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }

    func setFocused(_ value: Bool) { focused = value; updateGlow() }
    func setBusy(_ value: Bool) {
        busy = value
        if value && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.18; pulse.toValue = 0.7
            pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
            glow.add(pulse, forKey: "search-pulse")
        } else { glow.removeAnimation(forKey: "search-pulse") }
        updateGlow()
    }

    func acknowledge() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [focused ? 0.22 : 0, 0.75, focused ? 0.22 : 0]
        flash.keyTimes = [0, 0.25, 1]; flash.duration = 0.45
        glow.add(flash, forKey: "search-submit")
    }

    private func updateGlow() {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
        glow.opacity = busy ? 0.4 : (focused ? 0.22 : 0)
        layer?.borderColor = focused || busy ? NSColor(calibratedRed: 0.66, green: 0.55, blue: 0.96, alpha: 0.9).cgColor : borderTint(0.9).cgColor
        CATransaction.commit()
    }
}
