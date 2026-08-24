import AppKit

/// The live text box: an editable field with handles on its corners and edges.
/// Text wraps to the box, so dragging a handle reflows what has been typed
/// instead of scaling it — the same as resizing a text frame in a layout app.
final class TextBoxOverlay: NSView, NSTextViewDelegate {
    let textView = NSTextView()
    /// Called after a resize so the caller can keep its own geometry in step.
    var onResize: (() -> Void)?
    /// ⌘⏎ paints the text; ⎋ throws it away. Plain Return is a new line.
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// Half the side of a handle square, in view points.
    static let handleReach: CGFloat = 4
    /// Nothing useful fits in less than this.
    static let minimumSide: CGFloat = 16

    private var dragHandle: Int?
    private var dragStart: NSPoint = .zero
    private var startFrame: NSRect = .zero

    /// The box in image coordinates. The canvas keeps the view frame in step
    /// with this as the zoom or scroll changes, so the box stays on the pixels
    /// it was drawn around.
    var imageBox: CGRect = .zero
    /// Font at 100%: what is shown is this scaled to the current zoom.
    private(set) var baseFont: NSFont

    init(frame: NSRect, font: NSFont, color: NSColor) {
        self.baseFont = font
        super.init(frame: frame)
        wantsLayer = true
        textView.frame = bounds.insetBy(dx: TextBoxOverlay.handleReach, dy: TextBoxOverlay.handleReach)
        textView.autoresizingMask = [.width, .height]
        textView.font = font
        textView.textColor = color
        textView.backgroundColor = NSColor(white: 0, alpha: 0.12)
        textView.drawsBackground = true
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    var string: String { textView.string }

    /// Shows the text at the size it will be painted, for the current zoom.
    func apply(zoom: CGFloat) {
        let size = max(1, baseFont.pointSize * zoom)
        textView.font = NSFontManager.shared.convert(baseFont, toSize: size)
    }

    /// Recolors the text being typed, so a color picked mid-edit shows up in
    /// the box rather than only once the text is painted.
    func setColor(_ color: NSColor) {
        guard textView.textColor != color else { return }
        textView.textColor = color
        // Text already typed keeps the old color otherwise: the attribute is
        // on the storage, not the view.
        let all = NSRange(location: 0, length: textView.string.utf16.count)
        textView.textStorage?.addAttribute(.foregroundColor, value: color, range: all)
        textView.needsDisplay = true
    }

    func setBaseFont(_ font: NSFont, zoom: CGFloat) {
        baseFont = font
        apply(zoom: zoom)
    }

    /// The eight handle centres, corners first.
    var handles: [NSPoint] {
        let r = bounds.insetBy(dx: TextBoxOverlay.handleReach, dy: TextBoxOverlay.handleReach)
        return [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
                NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.midX, y: r.maxY),
                NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY)]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let reach = TextBoxOverlay.handleReach
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(bounds.insetBy(dx: reach, dy: reach))
        for h in handles {
            let box = NSRect(x: h.x - reach, y: h.y - reach, width: reach * 2, height: reach * 2)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.stroke(box)
        }
    }

    /// The handle under a point, if any. Handles sit outside the text view, so
    /// grabbing one never steals a click meant for the text.
    func handleIndex(at p: NSPoint) -> Int? {
        let reach = TextBoxOverlay.handleReach + 2
        for (i, h) in handles.enumerated()
        where abs(h.x - p.x) <= reach && abs(h.y - p.y) <= reach { return i }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if handleIndex(at: local) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        dragHandle = handleIndex(at: local)
        dragStart = event.locationInWindow
        startFrame = frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = dragHandle else { return }
        let dx = event.locationInWindow.x - dragStart.x
        let dy = event.locationInWindow.y - dragStart.y
        var r = startFrame
        // Corners move two edges, the rest move one.
        switch handle {
        case 0: r.origin.x += dx; r.size.width -= dx; r.origin.y += dy; r.size.height -= dy
        case 1: r.size.width += dx; r.origin.y += dy; r.size.height -= dy
        case 2: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
        case 3: r.size.width += dx; r.size.height += dy
        case 4: r.origin.y += dy; r.size.height -= dy
        case 5: r.size.height += dy
        case 6: r.origin.x += dx; r.size.width -= dx
        default: r.size.width += dx
        }
        let minimum = TextBoxOverlay.minimumSide + TextBoxOverlay.handleReach * 2
        if r.width < minimum { r.size.width = minimum; r.origin.x = startFrame.maxX - minimum }
        if r.height < minimum { r.size.height = minimum; r.origin.y = startFrame.maxY - minimum }
        frame = r
        needsDisplay = true
        onResize?()
    }

    override func mouseUp(with event: NSEvent) { dragHandle = nil }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘⏎ while typing means "done", the way a comment field works.
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resetCursorRects() {
        let reach = TextBoxOverlay.handleReach + 2
        for (i, h) in handles.enumerated() {
            let box = NSRect(x: h.x - reach, y: h.y - reach, width: reach * 2, height: reach * 2)
            addCursorRect(box, cursor: i == 4 || i == 5 ? .resizeUpDown : .resizeLeftRight)
        }
    }
}
