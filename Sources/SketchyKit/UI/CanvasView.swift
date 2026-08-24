import AppKit

protocol CanvasViewDelegate: AnyObject {
    func canvasDidChangeZoom(_ view: CanvasView)
    func canvas(_ view: CanvasView, didHoverAt point: CGPoint?)
    /// `box` is where the text should go, in image coordinates. A box with no
    /// width is a plain click: the caller picks a default size.
    func canvasWantsTextEntry(_ view: CanvasView, in box: CGRect)
    /// The canvas finished an edit on its own — dropping floating pixels, say
    /// — and the palettes need to catch up.
    func canvasDidCommitEdit(_ view: CanvasView)
    func canvasWantsDelete(_ view: CanvasView)
    func canvasDidChangeMeasurement(_ view: CanvasView)
    func canvas(_ view: CanvasView, didAdjustSetting message: String)
}

/// Draws the composited document and routes pointer input to the tool engine.
/// User space is not flipped, so view coordinates share the document's
/// bottom-left origin once the zoom/centering offset is removed.
final class CanvasView: NSView {
    weak var delegate: CanvasViewDelegate?
    var document: Document
    var engine: ToolEngine
    var settings: ToolSettings

    var zoom: CGFloat = 1.0 {
        didSet {
            zoom = min(32, max(0.05, zoom))
            invalidateIntrinsicContentSize()
            resizeToFit()
            layoutTextBox()
            needsDisplay = true
            delegate?.canvasDidChangeZoom(self)
        }
    }

    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?
    private var cachedComposite: CGImage?
    /// Where the pointer is, in image coordinates, for the brush ring.
    private var hoverPoint: CGPoint? {
        didSet {
            guard settings.tool.hasBrushTip, hoverPoint != oldValue else { return }
            needsDisplay = true
        }
    }
    private var cachedRegion: CGRect = .null
    private var cachedScale: CGFloat = 0
    private var compositeDirty = true
    private var panOrigin: NSPoint?
    /// Fractional wheel movement waiting to add up to a whole step.
    private var wheelSteps: CGFloat = 0
    /// The live text box, kept lined up with the canvas as it zooms.
    private(set) var textBox: TextBoxOverlay?
    /// Where a drag with the text tool began, and the box it has swept out.
    private var textBoxStart: CGPoint?
    private var textBoxRect: CGRect?
    /// Middle button pans from wherever the pointer is, then hands the canvas
    /// back to whatever tool was in use.

    init(document: Document, engine: ToolEngine, settings: ToolSettings) {
        self.document = document
        self.engine = engine
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        wantsLayer = true
        clipsToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        engine.onNeedsDisplay = { [weak self] in self?.refresh() }
        document.onChange = { [weak self] in self?.refresh() }
        // Scrolling changes which slice of the document is on screen.
        NotificationCenter.default.addObserver(self, selector: #selector(viewportMoved),
                                               name: NSView.boundsDidChangeNotification, object: nil)
        startAnts()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { antsTimer?.invalidate() }

    @objc private func viewportMoved(_ note: Notification) {
        guard let clip = note.object as? NSClipView, clip === enclosingScrollView?.contentView else { return }
        needsDisplay = true
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        compositeDirty = true
        needsDisplay = true
        delegate?.canvasDidChangeMeasurement(self)
    }

    func replaceDocument(_ doc: Document, engine: ToolEngine) {
        self.document = doc
        self.engine = engine
        engine.onNeedsDisplay = { [weak self] in self?.refresh() }
        doc.onChange = { [weak self] in self?.refresh() }
        resizeToFit()
        refresh()
    }

    // MARK: - Geometry

    var scaledSize: CGSize {
        CGSize(width: document.size.width * zoom, height: document.size.height * zoom)
    }

    /// Where the image sits inside this view, in view coordinates.
    var imageRect: CGRect {
        let s = scaledSize
        let x = max(0, (bounds.width - s.width) / 2).rounded()
        let y = max(0, (bounds.height - s.height) / 2).rounded()
        return CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: scaledSize.width + 40, height: scaledSize.height + 40)
    }

    func resizeToFit() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let s = scaledSize
        // Room to scroll past the edges, so a corner can sit anywhere on
        // screen and a zoom into one does not slide away from the pointer.
        // Capped: the scrollable area is a real cost at high zoom.
        let padX = min(max(40, clip.bounds.width * 0.5), 600)
        let padY = min(max(40, clip.bounds.height * 0.5), 600)
        let w = max(clip.bounds.width, s.width + padX * 2)
        let h = max(clip.bounds.height, s.height + padY * 2)
        setFrameSize(NSSize(width: w, height: h))
    }

    /// Zooms so the image point under `windowPoint` stays under it. Without an
    /// anchor the middle of what is on screen holds still, which is what the
    /// menu commands want.
    func setZoom(_ newZoom: CGFloat, anchoredAt windowPoint: NSPoint?) {
        guard let clip = enclosingScrollView?.contentView else {
            zoom = newZoom
            return
        }
        let visible = clip.documentVisibleRect
        let anchorInView = windowPoint.map { convert($0, from: nil) }
            ?? NSPoint(x: visible.midX, y: visible.midY)
        let anchorInImage = imagePoint(from: anchorInView)
        // Where the pointer sits inside the viewport, which is what has to
        // stay put — the view coordinate itself moves with the scroll.
        let inViewport = NSPoint(x: anchorInView.x - clip.bounds.origin.x,
                                 y: anchorInView.y - clip.bounds.origin.y)
        zoom = newZoom
        layoutSubtreeIfNeeded()
        let r = imageRect
        let moved = NSPoint(x: r.minX + anchorInImage.x * zoom,
                            y: r.minY + anchorInImage.y * zoom)
        // Stay inside the scrollable area: an origin outside it is snapped
        // back by AppKit anyway, and the snap is what makes a zoom jump.
        let limitX = max(0, bounds.width - clip.bounds.width)
        let limitY = max(0, bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: (moved.x - inViewport.x).clamped(to: 0...limitX),
                                y: (moved.y - inViewport.y).clamped(to: 0...limitY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    func imagePoint(from viewPoint: NSPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (viewPoint.x - r.minX) / zoom, y: (viewPoint.y - r.minY) / zoom)
    }

    func zoomToFit() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let sx = (clip.bounds.width - 60) / document.size.width
        let sy = (clip.bounds.height - 60) / document.size.height
        zoom = max(0.05, min(sx, sy))
    }

    /// The part of the document currently on screen, in image coordinates,
    /// rounded outwards so partial pixels are not clipped.
    private func visibleImageRect(in imageRect: CGRect) -> CGRect {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let region = CGRect(x: (visible.minX - imageRect.minX) / zoom,
                            y: (visible.minY - imageRect.minY) / zoom,
                            width: visible.width / zoom,
                            height: visible.height / zoom)
        return region.insetBy(dx: -1, dy: -1).integral.intersection(document.bounds)
    }

    // MARK: - Text box

    /// Puts a text box on the canvas at `box` (image coordinates) and keeps it
    /// there through zooming and scrolling.
    func showTextBox(_ overlay: TextBoxOverlay, at box: CGRect) {
        removeTextBox()
        overlay.imageBox = box
        addSubview(overlay)
        textBox = overlay
        overlay.onResize = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            overlay.imageBox = imageBox(forViewFrame: overlay.frame)
        }
        layoutTextBox()
        window?.makeFirstResponder(overlay.textView)
    }

    func removeTextBox() {
        textBox?.removeFromSuperview()
        textBox = nil
    }

    /// Frame the overlay needs so its box covers the same pixels as before.
    private func viewFrame(forImageBox box: CGRect) -> NSRect {
        let r = imageRect
        let reach = TextBoxOverlay.handleReach
        return NSRect(x: r.minX + box.minX * zoom - reach,
                      y: r.minY + box.minY * zoom - reach,
                      width: box.width * zoom + reach * 2,
                      height: box.height * zoom + reach * 2)
    }

    private func imageBox(forViewFrame frame: NSRect) -> CGRect {
        let r = imageRect
        let reach = TextBoxOverlay.handleReach
        return CGRect(x: (frame.minX + reach - r.minX) / zoom,
                      y: (frame.minY + reach - r.minY) / zoom,
                      width: max(1, frame.width - reach * 2) / zoom,
                      height: max(1, frame.height - reach * 2) / zoom)
    }

    func layoutTextBox() {
        guard let overlay = textBox else { return }
        overlay.frame = viewFrame(forImageBox: overlay.imageBox)
        overlay.apply(zoom: zoom)
        overlay.needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Scrolling and window resizing move the image under the box.
        layoutTextBox()
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        dirtyRect.intersection(bounds).fill()

        let r = imageRect
        // Bound the board by what is on screen whatever asked for the redraw:
        // a request to draw the whole view would otherwise walk every square
        // of a hugely zoomed canvas.
        ctx.saveGState()
        ctx.clip(to: visibleRect.insetBy(dx: -16, dy: -16))
        drawCheckerboard(in: r, cell: 8)
        ctx.restoreGState()

        // Only the visible slice of the document is composited, at the size it
        // is about to be drawn. A 20000 x 20000 canvas then costs the same to
        // redraw as a small one.
        let visibleInImage = visibleImageRect(in: r)
        let backingScale = window?.backingScaleFactor ?? 2
        let pixelScale = min(zoom, 1) * backingScale
        if compositeDirty || cachedComposite == nil
            || cachedRegion != visibleInImage || cachedScale != pixelScale {
            let pixelSize = CGSize(width: visibleInImage.width * pixelScale,
                                   height: visibleInImage.height * pixelScale)
            cachedComposite = document.composite(region: visibleInImage, pixelSize: pixelSize)
            cachedRegion = visibleInImage
            cachedScale = pixelScale
            compositeDirty = false
        }
        ctx.saveGState()
        ctx.interpolationQuality = zoom >= 1 ? .none : .high
        if let img = cachedComposite {
            // Draw the slice back where it came from.
            let onScreen = CGRect(x: r.minX + visibleInImage.minX * zoom,
                                  y: r.minY + visibleInImage.minY * zoom,
                                  width: visibleInImage.width * zoom,
                                  height: visibleInImage.height * zoom)
            ctx.draw(img, in: onScreen)
        }
        ctx.restoreGState()

        // Tool overlay + selection are drawn in image space.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.clip(to: document.bounds.insetBy(dx: -2 / zoom, dy: -2 / zoom))
        engine.viewScale = zoom
        engine.drawOverlay(in: ctx, scale: zoom)
        ctx.restoreGState()

        if let box = textBoxRect {
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.setLineWidth(1 / zoom)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.stroke(box)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 4 / zoom])
            ctx.stroke(box)
            ctx.restoreGState()
        }

        if let sel = document.selectionPath {
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.setLineWidth(1 / zoom)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addPath(sel); ctx.strokePath()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineDash(phase: antsPhase / zoom, lengths: [4 / zoom, 4 / zoom])
            ctx.addPath(sel); ctx.strokePath()
            ctx.restoreGState()
        }

        // Handles are drawn outside the canvas clip: a box dragged past the
        // edge still has to show the corner you grab to resize it.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        engine.drawChrome(in: ctx, scale: zoom)
        ctx.restoreGState()

        drawBrushRing(in: ctx, imageRect: r)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.35, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
    }

    /// Outlines what a brush or eraser is about to cover. Drawn in view space
    /// so the ring keeps a hairline outline at any zoom.
    private func drawBrushRing(in ctx: CGContext, imageRect r: CGRect) {
        guard settings.tool.hasBrushTip, let p = hoverPoint else { return }
        let radius = settings.brushWidth / 2 * zoom
        guard radius > 1 else { return }
        let center = CGPoint(x: r.minX + p.x * zoom, y: r.minY + p.y * zoom)
        let circle = CGRect(x: center.x - radius, y: center.y - radius,
                            width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.strokeEllipse(in: circle.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()
    }

    private func startAnts() {
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.document.selectionPath != nil else { return }
            self.antsPhase = (self.antsPhase + 1).truncatingRemainder(dividingBy: 8)
            self.needsDisplay = true
        }
        RunLoop.main.add(antsTimer!, forMode: .common)
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) { handleDown(event, right: false) }
    override func rightMouseDown(with event: NSEvent) { handleDown(event, right: true) }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        panOrigin = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard panOrigin != nil else { super.otherMouseDragged(with: event); return }
        panBy(to: convert(event.locationInWindow, from: nil))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard panOrigin != nil else { super.otherMouseUp(with: event); return }
        panOrigin = nil
        NSCursor.pop()
    }

    /// Scrolls the clip view so the point grabbed stays under the pointer.
    private func panBy(to vp: NSPoint) {
        guard let origin = panOrigin, let clip = enclosingScrollView?.contentView else { return }
        var o = clip.bounds.origin
        o.x -= vp.x - origin.x
        o.y -= vp.y - origin.y
        clip.scroll(to: o)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func handleDown(_ event: NSEvent, right: Bool) {
        let vp = convert(event.locationInWindow, from: nil)
        let p = imagePoint(from: vp)

        switch settings.tool {
        case .pan:
            panOrigin = vp
            return
        case .zoom:
            let factor: CGFloat = (event.modifierFlags.contains(.option) || right) ? 1 / 1.25 : 1.25
            setZoom(zoom * factor, anchoredAt: event.locationInWindow)
            return
        case .text:
            // The drag decides how big the box is; a plain click leaves it to
            // the caller.
            textBoxStart = p
            textBoxRect = nil
            return
        default:
            break
        }
        window?.makeFirstResponder(self)
        engine.mouseDown(at: p, rightButton: right, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) { handleDrag(event) }
    override func rightMouseDragged(with event: NSEvent) { handleDrag(event) }

    private func handleDrag(_ event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        if settings.tool == .pan, panOrigin != nil {
            panBy(to: vp)
            return
        }
        hoverPoint = imagePoint(from: vp)
        if let start = textBoxStart, settings.tool == .text {
            textBoxRect = CGRect(x: min(start.x, hoverPoint!.x), y: min(start.y, hoverPoint!.y),
                                 width: abs(hoverPoint!.x - start.x),
                                 height: abs(hoverPoint!.y - start.y))
            needsDisplay = true
            return
        }
        engine.mouseDragged(to: imagePoint(from: vp), modifiers: event.modifierFlags)
        delegate?.canvas(self, didHoverAt: imagePoint(from: vp))
    }

    override func mouseUp(with event: NSEvent) { handleUp(event) }
    override func rightMouseUp(with event: NSEvent) { handleUp(event) }

    private func handleUp(_ event: NSEvent) {
        panOrigin = nil
        let p = imagePoint(from: convert(event.locationInWindow, from: nil))
        if let start = textBoxStart, settings.tool == .text {
            textBoxStart = nil
            textBoxRect = nil
            needsDisplay = true
            let swept = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
            // Too small to have been meant as a box: treat it as a click.
            let box = swept.width < 8 || swept.height < 8
                ? CGRect(origin: start, size: .zero)
                : swept
            delegate?.canvasWantsTextEntry(self, in: box)
            return
        }
        engine.mouseUp(at: p, modifiers: event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = imagePoint(from: convert(event.locationInWindow, from: nil))
        hoverPoint = p
        delegate?.canvas(self, didHoverAt: document.bounds.contains(p) ? p : nil)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        delegate?.canvas(self, didHoverAt: nil)
    }

    override func keyDown(with event: NSEvent) {
        let arrows: [UInt16: (CGFloat, CGFloat)] = [123: (-1, 0), 124: (1, 0), 125: (0, -1), 126: (0, 1)]
        switch event.keyCode {
        case 36, 76:  // Return / Enter
            if engine.session != nil {
                engine.commitSession()
            } else if engine.hasFloatingPixels {
                // The status bar promises ⏎ drops them; it has to.
                engine.commitFloatingPixels()
                delegate?.canvasDidCommitEdit(self)
            } else {
                super.keyDown(with: event)
            }
        case 51, 117: // Delete / Forward Delete
            delegate?.canvasWantsDelete(self)
        case 53:      // Escape
            if engine.session != nil {
                engine.cancelSession()
            } else if engine.hasFloatingPixels {
                engine.cancelFloatingPixels()
                delegate?.canvasDidCommitEdit(self)
            } else {
                document.deselect()
            }
        case let code where arrows[code] != nil && engine.hasFloatingPixels:
            let (dx, dy) = arrows[event.keyCode]!
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            engine.nudgeFloatingPixels(dx: dx * step, dy: dy * step)
        case let code where arrows[code] != nil && engine.session != nil:
            let (dx, dy) = arrows[event.keyCode]!
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            if event.modifierFlags.contains(.option) {
                engine.adjustSession(dx: 0, dy: 0, rotation: (dx + dy) * .pi / 180 * step)
            } else {
                engine.adjustSession(dx: dx * step, dy: dy * step, rotation: 0)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY * 0.01
            setZoom(zoom * factor, anchoredAt: event.locationInWindow)
            return
        }
        // Option turns the wheel into the tool's dial: size, tolerance,
        // gradient strength — whatever that tool is mostly about.
        if event.modifierFlags.contains(.option),
           let option = settings.adjustable(secondary: event.modifierFlags.contains(.shift)) {
            wheelSteps += event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 12
                : event.scrollingDeltaY
            let steps = wheelSteps.rounded(.towardZero)
            guard steps != 0 else { return }
            wheelSteps -= steps
            delegate?.canvas(self, didAdjustSetting: settings.adjust(option, steps: steps))
            needsDisplay = true
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchoredAt: event.locationInWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch settings.tool {
        case .pan:         cursor = .openHand
        case .text:        cursor = .iBeam
        case .colorPicker: cursor = .crosshair
        case .zoom:        cursor = .crosshair
        default:           cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }
}
