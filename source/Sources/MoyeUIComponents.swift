import AppKit

final class MoyeCenteredTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = MoyeCenteredTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

private final class MoyeCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = min(result.height, cellSize(forBounds: result).height)
        result.origin.y += (result.height - height) / 2
        result.size.height = height
        return result
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, start: selStart, length: selLength)
    }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor, delegate: delegate, event: event)
    }
}

// Crop the source rectangle to the viewport aspect ratio, then draw at one uniform scale.
final class MoyeCoverView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        var source = NSRect(origin: .zero, size: image.size)
        let targetRatio = bounds.width / bounds.height
        let sourceRatio = source.width / source.height
        if sourceRatio > targetRatio {
            let width = source.height * targetRatio
            source.origin.x = (source.width - width) / 2
            source.size.width = width
        } else {
            let height = source.width / targetRatio
            source.origin.y = (source.height - height) / 2
            source.size.height = height
        }
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}

// A real tracking button covering the entire card, with no native button drawing.
final class MoyeCardHitButton: NSButton {
    var highlightChanged: ((Bool) -> Void)?
    override func draw(_ dirtyRect: NSRect) {}
    override func mouseDown(with event: NSEvent) {
        highlightChanged?(true)
        defer { highlightChanged?(false) }
        super.mouseDown(with: event)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
