import AppKit
import CoreGraphics

/// Interprets pointer input for the active tool and mutates the document.
/// Everything it receives is already in image coordinates (bottom-left origin).
final class ToolEngine {
    unowned let doc: Document
    let settings: ToolSettings
    var primaryColor: NSColor = .black
    var secondaryColor: NSColor = .white

    /// Live overlay the canvas renders on top of the composited image.
    /// How the in-progress preview is drawn: like the shape it will become,
    /// like a selection outline, or as a guide that is never rasterized.
    enum PreviewStyle { case shape, selection, guide }

    private(set) var previewPath: CGPath?
    private(set) var previewStyle: PreviewStyle = .shape
    var previewIsSelection: Bool { previewStyle == .selection }

    /// Scratch buffer holding the current paintbrush stroke as an alpha mask, so
    /// overlapping dabs don't darken each other mid-stroke.
    private var strokeScratch: Layer?
    /// Where the scratch buffer sits on the canvas. It covers the stroke so
    /// far rather than the whole document, which is the difference between a
    /// few megabytes and the size of the canvas on a large image.
    private var strokeScratchOrigin: CGPoint = .zero
    private var stampImage: CGImage?
    private var stampKey: String = ""

    /// Pixels lifted off a layer, or freshly pasted, that follow the pointer
    /// until they are committed. They keep their full size while floating, so
    /// dragging past the edge of the canvas and back loses nothing.
    private var floatingImage: CGImage?
    /// Where the floating pixels sit and how big they are. Resizing changes the
    /// size, so this is the source of truth rather than an offset.
    private var floatingFrame: CGRect = .zero
    private var floatingDragFrame: CGRect = .zero
    private var floatingGrab: SelectionGrab = .move
    /// What the layer looked like before pixels were lifted, so a cancel can
    /// put them back. Nil for a paste, which took nothing away.
    private var floatingUndoSnapshot: CGImage?
    /// The outline from before the float started, so a cancel restores it too.
    private var floatingStartSelection: CGPath?
    /// Set when a resize drag crossed the opposite edge and mirrored the pixels.
    /// How far the floating pixels have been turned, in radians.
    private var floatingAngle: CGFloat = 0
    private var floatingDragAngle: CGFloat = 0
    /// Pointer angle when a rotation drag began, so turning is relative.
    private var floatingGrabAngle: CGFloat = 0
    private var floatingFlippedX = false
    private var floatingFlippedY = false
    /// Flip state when the current drag began, so mirroring is derived from the
    /// drag rather than toggled on every pointer event.
    private var floatingDragFlipX = false
    private var floatingDragFlipY = false

    /// The rectangle worth measuring right now: the marquee being dragged, the
    /// pixels being moved, the shape being placed, or the standing selection.
    /// Nil when there is nothing to report.
    var measuredRect: CGRect? {
        if let preview = previewPath, previewIsSelection {
            let box = preview.boundingBoxOfPath
            return box.isNull || box.isEmpty ? nil : box
        }
        if hasFloatingPixels { return floatingRect }
        if let session { return sessionPath(session).boundingBoxOfPath }
        guard let selection = doc.selectionPath?.boundingBoxOfPath,
              !selection.isNull, !selection.isEmpty else { return nil }
        return selection
    }

    /// Whether the floating pixels are mirrored, for tests and for the overlay.
    var floatingIsMirrored: (x: Bool, y: Bool) { (floatingFlippedX, floatingFlippedY) }
    private var floatingTitle = "Move Selected Pixels"

    var hasFloatingPixels: Bool { floatingImage != nil }

    /// True while the floating pixels are still at their original size, which
    /// lets them be blitted without resampling.
    private var floatingIsUnscaled: Bool {
        guard let img = floatingImage else { return true }
        return Int(floatingFrame.width) == img.width && Int(floatingFrame.height) == img.height
    }

    /// A shape that has been drawn but not yet rasterized: it can still be
    /// moved, resized and rotated, exactly like Paint.NET's shape handles.
    struct ShapeSession {
        /// nil means the Line/Curve tool.
        var kind: ShapeKind?
        var p0: CGPoint
        var p1: CGPoint
        var angle: CGFloat = 0
        /// A drag that crosses the opposite edge mirrors the shape rather than
        /// pushing it along: p0/p1 always hold a positive rect, so the flip has
        /// to be remembered separately.
        var flipX = false
        var flipY = false

        var isLine: Bool { kind == nil }
        var rect: CGRect {
            CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                   width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        }
        var center: CGPoint { CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2) }
    }

    private enum Interaction {
        case none, creating, moving, resizing(Int), rotating
    }

    private(set) var session: ShapeSession?
    private var interaction: Interaction = .none
    private var grabPoint: CGPoint = .zero
    private var grabSession: ShapeSession?
    /// Canvas zoom, so handles keep a constant on-screen size.
    var viewScale: CGFloat = 1

    private var dragStart: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lassoPoints: [CGPoint] = []
    private var cloneSource: CGPoint?
    private var cloneDelta: CGSize?
    /// Anchor for the healing brush, kept apart from the clone stamp's so
    /// switching tools does not move either of them.
    private var healSource: CGPoint?
    private var healDelta: CGSize?
    private var isDragging = false
    private var usesSecondary = false
    private var startedSelection: CGPath?
    /// Mode for the drag in progress: the options bar setting unless a modifier
    /// overrides it.
    private var activeSelectionMode: SelectionMode = .replace
    /// Which part of the selection outline the current drag grabbed.
    private enum SelectionGrab { case none, move, resize(Int), rotate }
    private var selectionGrab: SelectionGrab = .none
    private var pendingCommitTitle: String?

    var onNeedsDisplay: (() -> Void)?
    var onColorPicked: ((NSColor, Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    init(doc: Document, settings: ToolSettings) {
        self.doc = doc
        self.settings = settings
    }

    var strokeColor: NSColor { usesSecondary ? secondaryColor : primaryColor }
    var fillColor: NSColor { usesSecondary ? primaryColor : secondaryColor }

    // MARK: - Pointer plumbing

    func mouseDown(at p: CGPoint, rightButton: Bool, modifiers: NSEvent.ModifierFlags) {
        usesSecondary = rightButton
        activeSelectionMode = ToolEngine.selectionMode(for: modifiers, default: settings.selectionMode)
        dragStart = p
        lastPoint = p
        isDragging = true
        startedSelection = doc.selectionPath
        previewPath = nil
        previewStyle = .shape

        // A group is a folder of layers, not a canvas: painting into one would
        // land in a bitmap that never gets drawn.
        if settings.tool.editsPixels, doc.selectedLayer?.isGroup == true {
            onStatus?("That is a group — select a layer inside it to paint")
            isDragging = false
            return
        }

        switch settings.tool {
        case .paintbrush, .pencil, .eraser:
            dab(from: p, to: p)
        case .recolor:
            recolorDab(at: p)
        case .cloneStamp:
            if modifiers.contains(.option) || modifiers.contains(.command) {
                cloneSource = p
                cloneDelta = nil
                onStatus?("Clone source set")
                isDragging = false
            } else if let src = cloneSource {
                if cloneDelta == nil { cloneDelta = CGSize(width: p.x - src.x, height: p.y - src.y) }
                cloneDab(at: p)
            } else {
                onStatus?("⌥-click to set the clone source first")
                isDragging = false
            }
        case .healingBrush:
            if modifiers.contains(.option) || modifiers.contains(.command) {
                healSource = p
                healDelta = nil
                onStatus?("Heal source set")
                isDragging = false
            } else if let src = healSource {
                if healDelta == nil { healDelta = CGSize(width: p.x - src.x, height: p.y - src.y) }
                healDab(from: p, to: p)
            } else {
                onStatus?("⌥-click to set the heal source first")
                isDragging = false
            }
        case .spotHealing:
            healDab(from: p, to: p)
        case .smudge, .blurBrush, .sharpenBrush:
            reworkDab(from: p, to: p)
        case .paintBucket:
            guard let layer = doc.selectedLayer else { break }
            PixelOps.floodFill(layer: layer,
                               seedX: Int(p.x), seedY: Int(p.y),
                               color: strokeColor,
                               tolerance: settings.tolerance,
                               contiguous: !settings.fillGlobally,
                               clip: doc.selectionPath,
                               blend: settings.blendMode.cgBlendMode)
            pendingCommitTitle = "Paint Bucket"
        case .colorPicker:
            pickColor(at: p, rightButton: rightButton)
            isDragging = false
        case .magicWand:
            magicWand(at: p, modifiers: modifiers)
            isDragging = false
        case .rectangleSelect, .ellipseSelect:
            clearSelectionIfReplacing()
        case .lassoSelect:
            clearSelectionIfReplacing()
            lassoPoints = [p]
        case .shapes, .line:
            beginShapeInteraction(at: p, modifiers: modifiers)
        case .moveSelection:
            selectionGrab = grabForSelection(at: p)
        case .moveSelectedPixels:
            if floatingImage == nil { liftFloatingPixels() }
            floatingGrab = grabForFloating(at: p)
            floatingDragFrame = floatingFrame
            floatingDragFlipX = floatingFlippedX
            floatingDragFlipY = floatingFlippedY
            floatingDragAngle = floatingAngle
            floatingGrabAngle = angle(from: floatingCentre(floatingFrame), to: p)
        default:
            break
        }
        onNeedsDisplay?()
    }

    /// Decides whether a click grabs a handle, moves, rotates, or starts fresh.
    private func beginShapeInteraction(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        if let s = session {
            if let handle = handleIndex(at: p, in: s) {
                interaction = .resizing(handle)
            } else if isInside(p, s) {
                interaction = .moving
            } else if rotationZone(for: s).contains(p) {
                interaction = .rotating
            } else {
                commitSession()
                interaction = .creating
                session = ShapeSession(kind: settings.tool == .line ? nil : settings.shape, p0: p, p1: p)
            }
        } else {
            interaction = .creating
            session = ShapeSession(kind: settings.tool == .line ? nil : settings.shape, p0: p, p1: p)
        }
        grabPoint = p
        grabSession = session
    }

    private func updateShapeInteraction(to p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var s = session, let start = grabSession else { return }
        switch interaction {
        case .creating:
            if s.isLine {
                var end = p
                if modifiers.contains(.shift) {
                    let dx = p.x - s.p0.x, dy = p.y - s.p0.y
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
                    let len = hypot(dx, dy)
                    end = CGPoint(x: s.p0.x + cos(angle) * len, y: s.p0.y + sin(angle) * len)
                }
                s.p1 = end
            } else {
                let anchor = grabPoint
                let r = constrained(anchor, p, modifiers: modifiers)
                s.p0 = CGPoint(x: r.minX, y: r.minY)
                s.p1 = CGPoint(x: r.maxX, y: r.maxY)
                s.flipX = p.x < anchor.x
                s.flipY = p.y < anchor.y
            }
        case .moving:
            let dx = p.x - grabPoint.x, dy = p.y - grabPoint.y
            s.p0 = CGPoint(x: start.p0.x + dx, y: start.p0.y + dy)
            s.p1 = CGPoint(x: start.p1.x + dx, y: start.p1.y + dy)
        case .resizing(let handle):
            resize(&s, from: start, handle: handle, to: p,
                   constrain: modifiers.contains(.shift))
        case .rotating:
            let c = start.center
            let a0 = atan2(grabPoint.y - c.y, grabPoint.x - c.x)
            let a1 = atan2(p.y - c.y, p.x - c.x)
            var angle = start.angle + (a1 - a0)
            if modifiers.contains(.shift) {
                let step = CGFloat.pi / 12  // 15° increments
                angle = (angle / step).rounded() * step
            }
            s.angle = angle
        case .none:
            return
        }
        session = s
    }

    func mouseDragged(to p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard isDragging else { return }
        defer { lastPoint = p; onNeedsDisplay?() }

        switch settings.tool {
        case .paintbrush, .pencil, .eraser:
            dab(from: lastPoint, to: p)
        case .recolor:
            recolorDab(at: p)
        case .cloneStamp:
            cloneDab(at: p)
        case .healingBrush, .spotHealing:
            healDab(from: lastPoint, to: p)
        case .smudge, .blurBrush, .sharpenBrush:
            reworkDab(from: lastPoint, to: p)
        case .lassoSelect:
            lassoPoints.append(p)
            previewPath = lassoPath(closed: false)
            previewStyle = .selection
        case .rectangleSelect, .ellipseSelect:
            previewPath = selectionShapePath(to: p, modifiers: modifiers)
            previewStyle = .selection
        case .line, .shapes:
            updateShapeInteraction(to: p, modifiers: modifiers)
        case .gradient:
            // A gradient has no outline to preview, only a direction, so the
            // drag shows the axis it is being pulled along.
            let guideLine = CGMutablePath()
            guideLine.move(to: dragStart)
            guideLine.addLine(to: p)
            previewPath = guideLine.copy()
            previewStyle = .guide
        case .moveSelection:
            dragSelection(to: p, modifiers: modifiers)
        case .moveSelectedPixels:
            dragFloating(to: p, modifiers: modifiers)
        default:
            break
        }
    }

    func mouseUp(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        defer {
            isDragging = false
            previewPath = nil
            previewStyle = .shape
            onNeedsDisplay?()
        }
        guard isDragging else {
            if let t = pendingCommitTitle { doc.commit(t); pendingCommitTitle = nil }
            return
        }

        switch settings.tool {
        case .paintbrush:
            commitStroke()
            doc.commit("Paintbrush")
        case .pencil:      doc.commit("Pencil")
        case .eraser:      doc.commit("Eraser")
        case .recolor:     doc.commit("Recolor")
        case .cloneStamp:  doc.commit("Clone Stamp")
        case .healingBrush: doc.commit("Healing Brush")
        case .spotHealing:  doc.commit("Spot Healing")
        case .smudge:       doc.commit("Smudge")
        case .blurBrush:    doc.commit("Blur")
        case .sharpenBrush: doc.commit("Sharpen")
        case .paintBucket:
            doc.commit(pendingCommitTitle ?? "Paint Bucket")
            pendingCommitTitle = nil
        case .rectangleSelect, .ellipseSelect:
            if isClickWithoutDrag(p) {
                handleSelectionClick(modifiers: modifiers)
            } else {
                applySelection(selectionShapePath(to: p, modifiers: modifiers))
            }
        case .lassoSelect:
            if isClickWithoutDrag(p), lassoPoints.count < 3 {
                handleSelectionClick(modifiers: modifiers)
            } else {
                lassoPoints.append(p)
                applySelection(lassoPath(closed: true))
            }
            lassoPoints = []
        case .line, .shapes:
            // The shape stays live so it can still be moved, resized or rotated.
            updateShapeInteraction(to: p, modifiers: modifiers)
            interaction = .none
            onStatus?("⏎ commits the shape, ⎋ cancels it")
        case .gradient:
            drawGradient(from: dragStart, to: p)
            doc.commit("Gradient")
        case .moveSelection:
            dragSelection(to: p, modifiers: modifiers)
            if case .resize = selectionGrab {
                doc.commit("Resize Selection")
            } else {
                doc.commit("Move Selection")
            }
            selectionGrab = .none
        case .moveSelectedPixels:
            // The pixels stay floating so they can be nudged again, or dragged
            // back in from beyond the canvas edge.
            moveFloatingSelection()
            onStatus?("⏎ drops the pixels, ⎋ puts them back")
        default:
            break
        }
    }

    // MARK: - Shape sessions

    private func transform(for s: ShapeSession) -> CGAffineTransform {
        let c = s.center
        return CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: s.angle)
            .translatedBy(x: -c.x, y: -c.y)
    }

    /// The session's outline in image coordinates, rotation included.
    func sessionPath(_ s: ShapeSession) -> CGPath {
        var t = transform(for: s)
        let base: CGPath
        if let kind = s.kind {
            let box = s.rect
            let shape = ShapeFactory.path(for: kind, in: box)
            if s.flipX || s.flipY {
                var mirror = CGAffineTransform(translationX: box.midX, y: box.midY)
                    .scaledBy(x: s.flipX ? -1 : 1, y: s.flipY ? -1 : 1)
                    .translatedBy(x: -box.midX, y: -box.midY)
                base = shape.copy(using: &mirror) ?? shape
            } else {
                base = shape
            }
        } else {
            let line = CGMutablePath()
            line.move(to: s.p0)
            line.addLine(to: s.p1)
            base = line.copy()!
        }
        return base.copy(using: &t) ?? base
    }

    /// Handle positions: both ends for a line, eight around the box otherwise.
    func sessionHandles(_ s: ShapeSession) -> [CGPoint] {
        let t = transform(for: s)
        if s.isLine { return [s.p0, s.p1].map { $0.applying(t) } }
        let r = s.rect
        return [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)
        ].map { $0.applying(t) }
    }

    /// Dragging inside this band — a fixed 24pt on screen, just outside the
    /// shape — rotates it. Anything further away commits and starts a new shape.
    private func rotationZone(for s: ShapeSession) -> CGRect {
        let band = 24 / viewScale
        let c = s.center
        let box = s.rect.insetBy(dx: -band, dy: -band)
        // Rotation is symmetric about the center, so the band follows the shape.
        return CGRect(x: c.x - box.width / 2, y: c.y - box.height / 2,
                      width: box.width, height: box.height).insetBy(dx: -0.5, dy: -0.5)
    }

    private func handleIndex(at p: CGPoint, in s: ShapeSession) -> Int? {
        let slop = max(4, 7 / viewScale)
        for (i, h) in sessionHandles(s).enumerated() where hypot(h.x - p.x, h.y - p.y) <= slop {
            return i
        }
        return nil
    }

    private func isInside(_ p: CGPoint, _ s: ShapeSession) -> Bool {
        // Un-rotate the point, then test against the plain box.
        let c = s.center
        let dx = p.x - c.x, dy = p.y - c.y
        let cosA = cos(-s.angle), sinA = sin(-s.angle)
        let local = CGPoint(x: c.x + dx * cosA - dy * sinA, y: c.y + dx * sinA + dy * cosA)
        if s.isLine {
            return s.rect.insetBy(dx: -max(4, settings.brushWidth), dy: -max(4, settings.brushWidth)).contains(local)
        }
        return s.rect.contains(local)
    }

    /// Every drag event is measured against the shape as it was when the
    /// handle was grabbed, so dragging past an edge and back mirrors once
    /// rather than flapping between the two.
    private func resize(_ s: inout ShapeSession, from start: ShapeSession,
                        handle: Int, to p: CGPoint, constrain: Bool) {
        if s.isLine {
            if handle == 0 { s.p0 = p } else { s.p1 = p }
            return
        }
        // Work in the session's own (un-rotated) space.
        let c = start.center
        let dx = p.x - c.x, dy = p.y - c.y
        let cosA = cos(-start.angle), sinA = sin(-start.angle)
        let local = CGPoint(x: c.x + dx * cosA - dy * sinA, y: c.y + dx * sinA + dy * cosA)

        var r = start.rect
        switch handle {
        case 0: r = CGRect(x: local.x, y: local.y, width: r.maxX - local.x, height: r.maxY - local.y)
        case 1: r = CGRect(x: r.minX, y: local.y, width: r.width, height: r.maxY - local.y)
        case 2: r = CGRect(x: r.minX, y: local.y, width: local.x - r.minX, height: r.maxY - local.y)
        case 3: r = CGRect(x: r.minX, y: r.minY, width: local.x - r.minX, height: r.height)
        case 4: r = CGRect(x: r.minX, y: r.minY, width: local.x - r.minX, height: local.y - r.minY)
        case 5: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: local.y - r.minY)
        case 6: r = CGRect(x: local.x, y: r.minY, width: r.maxX - local.x, height: local.y - r.minY)
        default: r = CGRect(x: local.x, y: r.minY, width: r.maxX - local.x, height: r.height)
        }
        // CGRect.width is always positive; only size keeps the sign, and the
        // sign is the whole question of whether the drag crossed over.
        let signed = r.size
        if constrain, signed.width != 0, signed.height != 0 {
            let side = max(abs(signed.width), abs(signed.height))
            r.size = CGSize(width: signed.width < 0 ? -side : side,
                            height: signed.height < 0 ? -side : side)
        }
        s.flipX = start.flipX != (signed.width < 0)
        s.flipY = start.flipY != (signed.height < 0)
        r = r.standardized
        s.p0 = CGPoint(x: r.minX, y: r.minY)
        s.p1 = CGPoint(x: r.maxX, y: r.maxY)
    }

    /// Rasterizes the pending shape onto the layer.
    @discardableResult
    func commitSession() -> Bool {
        guard let s = session, let layer = doc.selectedLayer else { return false }
        let path = sessionPath(s)
        let reach = settings.brushWidth + 4
        layer.markEdited(path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach))
        let ctx = layer.rawContext
        ctx.saveGState()
        doc.clipToSelection(ctx)
        ctx.setShouldAntialias(settings.antialiasing)
        ctx.setBlendMode(settings.blendMode.cgBlendMode)
        renderShape(path, in: ctx, bounds: doc.bounds)
        ctx.restoreGState()
        session = nil
        interaction = .none
        doc.commit(s.isLine ? "Line" : "Shape")
        onNeedsDisplay?()
        return true
    }

    func cancelSession() {
        guard session != nil else { return }
        session = nil
        interaction = .none
        onNeedsDisplay?()
    }

    /// Nudges or rotates the pending shape from the keyboard.
    func adjustSession(dx: CGFloat, dy: CGFloat, rotation: CGFloat) {
        guard var s = session else { return }
        s.p0.x += dx; s.p1.x += dx
        s.p0.y += dy; s.p1.y += dy
        s.angle += rotation
        session = s
        onNeedsDisplay?()
    }

    // MARK: - Moving and resizing the selection

    /// Handle positions around the selection: corners then edge midpoints.
    func selectionHandles() -> [CGPoint] {
        guard let box = doc.selectionPath?.boundingBoxOfPath, !box.isEmpty else { return [] }
        return [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.midX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.midY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.midX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.midY)
        ]
    }

    /// How close a click has to be to count as grabbing a handle. Capped on
    /// small regions so the handles cannot swallow the whole interior.
    private func handleSlop(for box: CGRect) -> CGFloat {
        min(max(4, 7 / viewScale), min(box.width, box.height) / 3)
    }

    private func grab(at p: CGPoint, handles: [CGPoint], box: CGRect) -> SelectionGrab {
        let slop = handleSlop(for: box)
        // Anywhere comfortably inside is a move, whatever the handles say.
        if box.insetBy(dx: slop, dy: slop).contains(p) { return .move }
        for (i, handle) in handles.enumerated()
        where hypot(handle.x - p.x, handle.y - p.y) <= slop {
            return .resize(i)
        }
        return .move
    }

    private func grabForSelection(at p: CGPoint) -> SelectionGrab {
        guard let box = doc.selectionPath?.boundingBoxOfPath else { return .move }
        return grab(at: p, handles: selectionHandles(), box: box)
    }

    /// Moves the whole outline, or scales it so the grabbed handle follows the
    /// pointer while the opposite edge stays put.
    private func dragSelection(to p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let original = startedSelection else { return }
        let box = original.boundingBoxOfPath
        guard !box.isEmpty else { return }

        switch selectionGrab {
        case .none, .rotate:
            return
        case .move:
            var t = CGAffineTransform(translationX: p.x - dragStart.x, y: p.y - dragStart.y)
            doc.selectionPath = original.copy(using: &t)
        case .resize(let handle):
            let movesLeft = [0, 6, 7].contains(handle)
            let movesRight = [2, 3, 4].contains(handle)
            let movesBottom = [0, 1, 2].contains(handle)
            let movesTop = [4, 5, 6].contains(handle)

            let anchorX = movesLeft ? box.maxX : box.minX
            let anchorY = movesBottom ? box.maxY : box.minY
            var width = movesLeft ? anchorX - p.x : (movesRight ? p.x - anchorX : box.width)
            var height = movesBottom ? anchorY - p.y : (movesTop ? p.y - anchorY : box.height)

            if modifiers.contains(.shift), box.width > 0, box.height > 0 {
                let scale = max(abs(width) / box.width, abs(height) / box.height)
                width = box.width * scale * (width < 0 ? -1 : 1)
                height = box.height * scale * (height < 0 ? -1 : 1)
            }

            // Dragging past the anchor mirrors the outline, the way dragging a
            // shape handle inside out does.
            let scaleX = width / max(0.0001, box.width) * (movesLeft ? 1 : 1)
            let scaleY = height / max(0.0001, box.height)
            let spanX = movesLeft ? -width : width
            let spanY = movesBottom ? -height : height
            let originX = min(anchorX, anchorX + spanX)
            let originY = min(anchorY, anchorY + spanY)

            var t = CGAffineTransform(translationX: originX, y: originY)
                .scaledBy(x: abs(scaleX), y: abs(scaleY))
                .translatedBy(x: -box.minX, y: -box.minY)
            if width < 0 || height < 0 {
                // Mirror about the resized box's own centre.
                let resized = CGRect(x: originX, y: originY,
                                     width: abs(width), height: abs(height))
                var mirror = CGAffineTransform(translationX: resized.midX, y: resized.midY)
                    .scaledBy(x: width < 0 ? -1 : 1, y: height < 0 ? -1 : 1)
                    .translatedBy(x: -resized.midX, y: -resized.midY)
                let scaled = original.copy(using: &t) ?? original
                doc.selectionPath = scaled.copy(using: &mirror)
                doc.onChange?()
                return
            }
            doc.selectionPath = original.copy(using: &t)
        }
        doc.onChange?()
    }

    // MARK: - Painting

    /// A context set up for a dab or stroke. `region` is what is about to
    /// change, which is what keeps an undo step small.
    private func brushContext(_ layer: Layer, region: CGRect? = nil) -> CGContext {
        layer.markEdited(region)
        let ctx = layer.rawContext
        ctx.saveGState()
        doc.clipToSelection(ctx)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(settings.antialiasing && settings.tool != .pencil)
        return ctx
    }

    /// A single soft round dab, cached because it only depends on size/hardness.
    private func brushStamp(diameter: CGFloat, hardness: CGFloat, color: NSColor) -> CGImage? {
        let size = max(2, Int(diameter.rounded()))
        let rgba = color.srgb
        let key = "\(size)-\(Int(hardness * 100))-\(rgba.hexString)"
        if key == stampKey, let stampImage { return stampImage }

        let l = Layer(width: size, height: size, name: "stamp")
        let ctx = l.context
        let c = CGFloat(size) / 2
        if hardness >= 0.99 {
            ctx.setFillColor(rgba.cgColor)
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        } else {
            // Opaque core out to `hardness`, fading to nothing at the rim.
            let solid = rgba.cgColor
            let clear = rgba.withAlphaComponent(0).cgColor
            let colors = [solid, solid, clear]
            let stops: [CGFloat] = [0, max(0.01, hardness * 0.9), 1]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: stops) {
                ctx.drawRadialGradient(grad,
                                       startCenter: CGPoint(x: c, y: c), startRadius: 0,
                                       endCenter: CGPoint(x: c, y: c), endRadius: c,
                                       options: [])
            }
        }
        stampImage = l.image
        stampKey = key
        return stampImage
    }

    /// Stamps the dab along a segment into the scratch mask using `.lighten`,
    /// which keeps the highest alpha instead of accumulating it.
    private func stampStroke(from a: CGPoint, to b: CGPoint, into scratch: Layer) {
        let width = settings.brushWidth
        guard let stamp = brushStamp(diameter: width, hardness: settings.hardness,
                                     color: strokeColor) else { return }
        let spacing = max(0.5, width * 0.12)
        let distance = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(distance / spacing))
        let ctx = scratch.context
        ctx.saveGState()
        ctx.setBlendMode(.lighten)
        for i in 0...steps {
            let t = steps == 0 ? 0 : CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            ctx.draw(stamp, in: CGRect(x: p.x - strokeScratchOrigin.x - width / 2,
                                       y: p.y - strokeScratchOrigin.y - width / 2,
                                       width: width, height: width))
        }
        ctx.restoreGState()
    }

    /// Where the scratch currently lives on the canvas.
    private var strokeScratchRect: CGRect {
        guard let scratch = strokeScratch else { return .zero }
        return CGRect(x: strokeScratchOrigin.x, y: strokeScratchOrigin.y,
                      width: CGFloat(scratch.width), height: CGFloat(scratch.height))
    }

    /// Makes sure the scratch covers `needed`, growing it in blocks so a long
    /// stroke does not reallocate on every dab.
    private func growScratch(toCover needed: CGRect) {
        let block: CGFloat = 256
        let padded = needed.insetBy(dx: -block / 2, dy: -block / 2)
        if strokeScratch != nil, strokeScratchRect.contains(padded) { return }

        var union = strokeScratch == nil ? padded : strokeScratchRect.union(padded)
        union = union.intersection(doc.bounds.insetBy(dx: -block, dy: -block))
        guard !union.isEmpty else { return }

        // Snap outwards to whole blocks.
        let origin = CGPoint(x: (union.minX / block).rounded(.down) * block,
                             y: (union.minY / block).rounded(.down) * block)
        let size = CGSize(width: ((union.maxX - origin.x) / block).rounded(.up) * block,
                          height: ((union.maxY - origin.y) / block).rounded(.up) * block)

        let grown = Layer(width: max(1, Int(size.width)), height: max(1, Int(size.height)), name: "stroke")
        if let old = strokeScratch, let image = old.image {
            grown.context.draw(image, in: CGRect(x: strokeScratchOrigin.x - origin.x,
                                                 y: strokeScratchOrigin.y - origin.y,
                                                 width: CGFloat(old.width), height: CGFloat(old.height)))
        }
        strokeScratch = grown
        strokeScratchOrigin = origin
    }

    private func commitStroke() {
        guard let scratch = strokeScratch, let layer = doc.selectedLayer,
              let image = scratch.image else { strokeScratch = nil; return }
        layer.markEdited(strokeScratchRect)
        let ctx = layer.rawContext
        ctx.saveGState()
        doc.clipToSelection(ctx)
        ctx.setBlendMode(settings.blendMode.cgBlendMode)
        ctx.draw(image, in: strokeScratchRect)
        ctx.restoreGState()
        strokeScratch = nil
    }

    private func dab(from a: CGPoint, to b: CGPoint) {
        guard let layer = doc.selectedLayer else { return }
        if settings.tool == .paintbrush {
            let reach = settings.brushWidth
            growScratch(toCover: CGRect(x: min(a.x, b.x) - reach, y: min(a.y, b.y) - reach,
                                        width: abs(b.x - a.x) + reach * 2,
                                        height: abs(b.y - a.y) + reach * 2))
            guard let scratch = strokeScratch else { return }
            stampStroke(from: a, to: b, into: scratch)
            return
        }
        let width = settings.tool == .pencil ? 1 : settings.brushWidth
        let touched = CGRect(x: min(a.x, b.x) - width, y: min(a.y, b.y) - width,
                             width: abs(b.x - a.x) + width * 2, height: abs(b.y - a.y) + width * 2)
        let ctx = brushContext(layer, region: touched)
        ctx.setLineWidth(width)
        if settings.tool == .eraser {
            ctx.setBlendMode(.clear)
            ctx.setStrokeColor(NSColor.black.cgColor)
        } else {
            ctx.setBlendMode(settings.blendMode.cgBlendMode)
            ctx.setStrokeColor(strokeColor.srgb.cgColor)
        }
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func recolorDab(at p: CGPoint) {
        guard let layer = doc.selectedLayer else { return }
        let r = CGRect(x: p.x - settings.brushWidth / 2, y: p.y - settings.brushWidth / 2,
                       width: settings.brushWidth, height: settings.brushWidth)
        PixelOps.recolor(layer: layer, in: r,
                         from: usesSecondary ? primaryColor : secondaryColor,
                         to: usesSecondary ? secondaryColor : primaryColor,
                         tolerance: settings.tolerance)
    }

    private func cloneDab(at p: CGPoint) {
        guard let layer = doc.selectedLayer, let delta = cloneDelta, let src = layer.image else { return }
        let d = settings.brushWidth
        let ctx = brushContext(layer, region: CGRect(x: p.x - d / 2 - 1, y: p.y - d / 2 - 1,
                                                     width: d + 2, height: d + 2))
        ctx.addEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
        ctx.clip()
        ctx.draw(src, in: CGRect(x: -delta.width, y: -delta.height,
                                 width: CGFloat(layer.width), height: CGFloat(layer.height)))
        ctx.restoreGState()
    }

    /// Heals along a segment. The healing brush takes its texture from the
    /// anchor the user set; spot healing finds the calmest patch nearby for
    /// each dab, so a blemish can be wiped out without picking a source.
    private func healDab(from a: CGPoint, to b: CGPoint) {
        guard let layer = doc.selectedLayer else { return }
        let diameter = settings.brushWidth
        let spacing = max(1, diameter * 0.35)
        let distance = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(distance / spacing))
        for i in 0...steps {
            let t = steps == 0 ? 0 : CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let offset: CGSize?
            if settings.tool == .healingBrush {
                offset = healDelta.map { CGSize(width: -$0.width, height: -$0.height) }
            } else {
                offset = PixelOps.bestHealSource(layer: layer, at: p, diameter: diameter)
            }
            guard let offset else { continue }
            PixelOps.heal(layer: layer, at: p, diameter: diameter, offset: offset,
                          hardness: settings.hardness, clip: doc.selectionPath)
        }
    }

    /// Smudge, blur and sharpen: dabs that rework what is already there
    /// rather than laying down colour.
    private func reworkDab(from a: CGPoint, to b: CGPoint) {
        guard let layer = doc.selectedRasterLayer else { return }
        let diameter = settings.brushWidth
        let spacing = max(1, diameter * 0.25)
        let distance = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(distance / spacing))
        var previous = a
        for i in 0...steps {
            let t = steps == 0 ? 0 : CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            switch settings.tool {
            case .smudge:
                PixelOps.smudgeDab(layer: layer, from: previous, to: p, diameter: diameter,
                                   strength: settings.brushStrength, hardness: settings.hardness,
                                   clip: doc.selectionPath)
            case .blurBrush:
                PixelOps.blurDab(layer: layer, at: p, diameter: diameter,
                                 strength: settings.brushStrength, hardness: settings.hardness,
                                 clip: doc.selectionPath)
            default:
                PixelOps.sharpenDab(layer: layer, at: p, diameter: diameter,
                                    strength: settings.brushStrength, hardness: settings.hardness,
                                    clip: doc.selectionPath)
            }
            previous = p
        }
    }

    private func pickColor(at p: CGPoint, rightButton: Bool) {
        let source: Layer? = settings.sampleMerged
            ? {
                guard let img = doc.composite() else { return nil }
                let l = Layer(width: doc.width, height: doc.height, name: "merged")
                l.draw(image: img); return l
            }()
            : doc.selectedLayer
        guard let layer = source,
              let px = PixelOps.sample(layer, x: Int(p.x), y: Int(p.y)) else { return }
        onColorPicked?(PixelOps.color(from: px), rightButton)
    }

    // MARK: - Shapes, lines, gradients

    private func constrained(_ start: CGPoint, _ end: CGPoint, modifiers: NSEvent.ModifierFlags) -> CGRect {
        var e = end
        if modifiers.contains(.shift) {
            let side = max(abs(e.x - start.x), abs(e.y - start.y))
            e.x = start.x + (e.x < start.x ? -side : side)
            e.y = start.y + (e.y < start.y ? -side : side)
        }
        return CGRect(x: min(start.x, e.x), y: min(start.y, e.y),
                      width: abs(e.x - start.x), height: abs(e.y - start.y))
    }

    /// Shared by the live preview and the committed draw so they look identical.
    func renderShape(_ path: CGPath, in ctx: CGContext, bounds: CGRect) {
        let filled = settings.tool != .line
            && (settings.drawMode == .fill || settings.drawMode == .outlineAndFill)
            && settings.fillStyle != .none
        if filled {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            paintFill(in: ctx, rect: path.boundingBoxOfPath)
            ctx.restoreGState()
        }
        let stroked = settings.tool == .line
            || settings.drawMode == .outline || settings.drawMode == .outlineAndFill
        if stroked {
            ctx.saveGState()
            ctx.setLineWidth(settings.brushWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if let pattern = settings.strokeStyle.pattern {
                ctx.setLineDash(phase: 0, lengths: pattern.map { $0 * max(1, settings.brushWidth / 2) })
            }
            ctx.setStrokeColor(strokeColor.srgb.cgColor)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func paintFill(in ctx: CGContext, rect: CGRect) {
        let color = fillColor.srgb
        switch settings.fillStyle {
        case .none:
            break
        case .solidColor:
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .horizontalLines, .verticalLines, .diagonalLines, .checker:
            ctx.setFillColor(color.cgColor)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            let step: CGFloat = 6
            switch settings.fillStyle {
            case .horizontalLines:
                var y = rect.minY
                while y < rect.maxY { ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
                ctx.strokePath()
            case .verticalLines:
                var x = rect.minX
                while x < rect.maxX { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
                ctx.strokePath()
            case .diagonalLines:
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    ctx.move(to: CGPoint(x: x, y: rect.minY))
                    ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
                    x += step
                }
                ctx.strokePath()
            default: // checker
                var y = rect.minY; var row = 0
                while y < rect.maxY {
                    var x = rect.minX + (row % 2 == 0 ? 0 : step)
                    while x < rect.maxX { ctx.fill(CGRect(x: x, y: y, width: step, height: step)); x += step * 2 }
                    y += step; row += 1
                }
            }
        }
    }

    private func drawGradient(from a: CGPoint, to b: CGPoint) {
        guard let layer = doc.selectedLayer else { return }
        let start = (usesSecondary ? secondaryColor : primaryColor).srgb
        let end = (usesSecondary ? primaryColor : secondaryColor).srgb
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [start.cgColor, end.cgColor] as CFArray,
                                    locations: [0, 1]) else { return }
        let ctx = layer.context
        ctx.saveGState()
        doc.clipToSelection(ctx)
        ctx.setBlendMode(settings.blendMode.cgBlendMode)
        ctx.setAlpha(settings.gradientStrength)
        switch settings.gradientKind {
        case .linear:
            ctx.drawLinearGradient(grad, start: a, end: b,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .reflected:
            let mirrored = CGPoint(x: a.x - (b.x - a.x), y: a.y - (b.y - a.y))
            ctx.drawLinearGradient(grad, start: a, end: b, options: [.drawsAfterEndLocation])
            ctx.drawLinearGradient(grad, start: a, end: mirrored, options: [.drawsAfterEndLocation])
        case .radial:
            ctx.drawRadialGradient(grad, startCenter: a, startRadius: 0,
                                   endCenter: a, endRadius: max(1, hypot(b.x - a.x, b.y - a.y)),
                                   options: [.drawsAfterEndLocation])
        case .conical:
            // Approximated with wedges around the origin point.
            let radius = max(1, hypot(b.x - a.x, b.y - a.y)) * 2
            let base = atan2(b.y - a.y, b.x - a.x)
            let steps = 180
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                let a0 = base + t * 2 * .pi
                let a1 = base + (t + 1.0 / CGFloat(steps)) * 2 * .pi
                let wedge = start.blended(withFraction: t, of: end) ?? start
                ctx.setFillColor(wedge.srgb.cgColor)
                ctx.move(to: a)
                ctx.addArc(center: a, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.closePath()
                ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    // MARK: - Text

    /// Paints text into `box`, wrapping to its width the way the live text box
    /// did while it was being typed.
    func commitText(_ string: NSAttributedString, in box: CGRect) {
        guard let layer = doc.selectedRasterLayer, string.length > 0, !box.isEmpty else { return }
        layer.markEdited(box.insetBy(dx: -2, dy: -2))
        let ctx = layer.rawContext
        ctx.saveGState()
        doc.clipToSelection(ctx)
        ctx.setBlendMode(settings.blendMode.cgBlendMode)
        ctx.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: box, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
        doc.commit("Text")
        onNeedsDisplay?()
    }

    // MARK: - Selection

    private func selectionShapePath(to p: CGPoint, modifiers: NSEvent.ModifierFlags) -> CGPath {
        let r = constrained(dragStart, p, modifiers: modifiers).integral
        return settings.tool == .ellipseSelect
            ? CGPath(ellipseIn: r, transform: nil)
            : CGPath(rect: r, transform: nil)
    }

    /// True when the pointer never really moved, which reads as a click.
    private func isClickWithoutDrag(_ p: CGPoint) -> Bool {
        hypot(p.x - dragStart.x, p.y - dragStart.y) < 1
    }

    /// A click on the canvas drops the selection. With a combining modifier
    /// held it does nothing instead, since the intent there was to keep what
    /// is already selected.
    private func handleSelectionClick(modifiers: NSEvent.ModifierFlags) {
        guard activeSelectionMode == .replace else {
            doc.selectionPath = startedSelection
            doc.onChange?()
            return
        }
        guard startedSelection != nil else { doc.selectionPath = nil; return }
        doc.selectionPath = nil
        doc.commit("Deselect")
        doc.onChange?()
    }

    private func lassoPath(closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard let first = lassoPoints.first else { return p.copy()! }
        p.move(to: first)
        for pt in lassoPoints.dropFirst() { p.addLine(to: pt) }
        if closed { p.closeSubpath() }
        return p.copy()!
    }

    /// A replacing drag drops the previous selection immediately, rather than
    /// leaving it on screen until the mouse comes up.
    private func clearSelectionIfReplacing() {
        guard activeSelectionMode == .replace, doc.selectionPath != nil else { return }
        doc.selectionPath = nil
        doc.onChange?()
    }

    /// ⌥ adds to the selection and ⌘ takes away, whatever the options bar says.
    /// ⇧ is left alone because the selection tools use it to constrain shape.
    static func selectionMode(for modifiers: NSEvent.ModifierFlags,
                              default fallback: SelectionMode) -> SelectionMode {
        if modifiers.contains(.option) && modifiers.contains(.command) { return .intersect }
        if modifiers.contains(.option) { return .union }
        if modifiers.contains(.command) { return .exclude }
        return fallback
    }

    /// What a selection made with the current tool is called in the history.
    private var selectionStepTitle: String {
        switch activeSelectionMode {
        case .replace:   return settings.tool.title
        case .union:     return "Add to Selection"
        case .exclude:   return "Subtract from Selection"
        case .intersect: return "Intersect Selection"
        case .xor:       return "Xor Selection"
        }
    }

    private func applySelection(_ new: CGPath) {
        guard !new.isEmpty else {
            guard doc.selectionPath != nil else { return }
            doc.selectionPath = nil
            doc.commit("Deselect")
            doc.onChange?()
            return
        }
        let mode = activeSelectionMode
        if let existing = startedSelection, mode != .replace {
            switch mode {
            case .union:     doc.selectionPath = existing.union(new)
            case .exclude:   doc.selectionPath = existing.subtracting(new)
            case .intersect: doc.selectionPath = existing.intersection(new)
            case .xor:       doc.selectionPath = existing.symmetricDifference(new)
            case .replace:   doc.selectionPath = new
            }
        } else {
            doc.selectionPath = new
        }
        // A selection is an edit like any other: it belongs in the history so
        // it can be undone and stepped back to.
        doc.commit(selectionStepTitle)
        doc.onChange?()
    }

    private func magicWand(at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let layer = doc.selectedLayer,
              let masked = PixelOps.maskedRegion(in: layer, seedX: Int(p.x), seedY: Int(p.y),
                                                 tolerance: settings.tolerance,
                                                 contiguous: !settings.fillGlobally) else { return }
        applySelection(PixelOps.path(from: masked.flags, width: layer.width, height: layer.height,
                                     bounds: masked.bounds))
    }

    // MARK: - Floating pixels

    private func liftFloatingPixels() {
        guard let layer = doc.selectedRasterLayer, let full = layer.image else {
            onStatus?("That is a group — select a layer inside it first")
            return
        }
        let sel = doc.selectionPath ?? CGPath(rect: doc.bounds, transform: nil)
        let box = sel.boundingBoxOfPath.integral.intersection(doc.bounds)
        guard !box.isEmpty else { return }

        let cut = Layer(width: Int(box.width), height: Int(box.height), name: "float")
        cut.context.saveGState()
        cut.context.translateBy(x: -box.minX, y: -box.minY)
        cut.context.addPath(sel)
        cut.context.clip(using: .evenOdd)
        cut.context.draw(full, in: doc.bounds)
        cut.context.restoreGState()
        floatingImage = cut.image
        floatingFrame = box
        floatingDragFrame = box
        floatingGrab = .move
        floatingFlippedX = false
        floatingFlippedY = false
        floatingDragFlipX = false
        floatingDragFlipY = false
        floatingAngle = 0
        floatingDragAngle = 0
        floatingUndoSnapshot = full
        floatingStartSelection = doc.selectionPath
        floatingTitle = "Move Selected Pixels"
        installFloatingOverlay()

        // Erase the lifted pixels from the source layer.
        layer.context.saveGState()
        layer.context.addPath(sel)
        layer.context.clip(using: .evenOdd)
        layer.context.clear(doc.bounds)
        layer.context.restoreGState()
    }

    /// Starts a floating session from pasted pixels. Nothing is drawn into the
    /// layer yet, so an image bigger than the canvas survives being moved.
    func beginFloatingPaste(_ image: CGImage, at origin: CGPoint) {
        commitFloatingPixels()
        floatingImage = image
        floatingFrame = CGRect(x: origin.x.rounded(), y: origin.y.rounded(),
                               width: CGFloat(image.width), height: CGFloat(image.height))
        floatingDragFrame = floatingFrame
        floatingGrab = .move
        floatingFlippedX = false
        floatingFlippedY = false
        floatingDragFlipX = false
        floatingDragFlipY = false
        floatingAngle = 0
        floatingDragAngle = 0
        floatingUndoSnapshot = nil
        floatingStartSelection = doc.selectionPath
        floatingTitle = "Paste"
        installFloatingOverlay()
        doc.selectionPath = CGPath(rect: floatingRect, transform: nil)
        doc.onChange?()
        onNeedsDisplay?()
    }

    /// Keeps the floating pixels drawn in their layer's place in the stack,
    /// so anything above them covers them the way it will once they land.
    private func installFloatingOverlay() {
        doc.layerOverlay = { [weak self] layer, ctx in
            guard let self, let img = floatingImage, layer === doc.selectedRasterLayer else { return }
            ctx.saveGState()
            ctx.interpolationQuality = floatingIsUnscaled && floatingAngle == 0
                ? .none : settings.resampling.quality
            drawFloating(img, in: ctx)
            ctx.restoreGState()
        }
    }

    private func removeFloatingOverlay() {
        doc.layerOverlay = nil
    }

    /// Where the floating pixels currently sit, in image coordinates.
    var floatingRect: CGRect { floatingImage == nil ? .zero : floatingFrame }

    /// The turn applied to the floating pixels, about the middle of their box.
    var floatingRotation: CGFloat { floatingAngle }

    private var floatingTransform: CGAffineTransform {
        let c = floatingCentre(floatingFrame)
        return CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: floatingAngle)
            .translatedBy(x: -c.x, y: -c.y)
    }

    /// A pointer position expressed in the box's own upright frame, so the
    /// resize maths never has to think about the rotation.
    private func upright(_ p: CGPoint) -> CGPoint {
        p.applying(floatingTransform.inverted())
    }

    private func floatingCentre(_ r: CGRect) -> CGPoint {
        CGPoint(x: r.midX, y: r.midY)
    }

    private func angle(from centre: CGPoint, to p: CGPoint) -> CGFloat {
        atan2(p.y - centre.y, p.x - centre.x)
    }

    /// The outline of the floating pixels, turned as they are.
    func floatingOutline() -> CGPath {
        var t = floatingTransform
        let box = CGPath(rect: floatingFrame, transform: nil)
        return box.copy(using: &t) ?? box
    }

    /// Where the rotation knob sits: off the top edge, turned with the box.
    func floatingRotationKnob() -> CGPoint? {
        guard floatingImage != nil else { return nil }
        let r = floatingFrame
        let reach = max(14 / viewScale, 10)
        return CGPoint(x: r.midX, y: r.maxY + reach).applying(floatingTransform)
    }

    /// Handles around the floating pixels, in the same order as the selection's.
    func floatingHandles() -> [CGPoint] {
        guard floatingImage != nil else { return [] }
        let r = floatingFrame
        let t = floatingTransform
        return [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)
        ].map { $0.applying(t) }
    }

    private func grabForFloating(at p: CGPoint) -> SelectionGrab {
        // The knob wins: it sits outside the box, where nothing else listens.
        if let knob = floatingRotationKnob() {
            let slop = max(6, 9 / viewScale)
            if hypot(knob.x - p.x, knob.y - p.y) <= slop { return .rotate }
        }
        return grab(at: upright(p), handles: floatingHandles().map(upright), box: floatingFrame)
    }

    /// Moves or scales the floating pixels. Movement snaps to whole pixels so
    /// unscaled content stays aligned to the grid and needs no resampling.
    private func dragFloating(to p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard floatingImage != nil else { return }
        let start = floatingDragFrame

        switch floatingGrab {
        case .none:
            return
        case .rotate:
            var turn = angle(from: floatingCentre(start), to: p) - floatingGrabAngle
            if modifiers.contains(.shift) {
                // Shift snaps to 15°, for uprighting something by eye.
                let step = CGFloat.pi / 12
                turn = (turn / step).rounded() * step
            }
            floatingAngle = floatingDragAngle + turn
        case .move:
            let dx = (p.x - dragStart.x).rounded()
            let dy = (p.y - dragStart.y).rounded()
            floatingFrame = start.offsetBy(dx: dx, dy: dy)
        case .resize(let handle):
            // Resizing happens in the box's own upright frame; the rotation is
            // put back when the pixels are drawn.
            let p = upright(p)
            // Work in signed edge offsets: CGRect standardises a negative size
            // away, so a rectangle cannot tell us the drag crossed its anchor.
            let movesLeft = [0, 6, 7].contains(handle)
            let movesRight = [2, 3, 4].contains(handle)
            let movesBottom = [0, 1, 2].contains(handle)
            let movesTop = [4, 5, 6].contains(handle)

            let anchorX = movesLeft ? start.maxX : start.minX
            let anchorY = movesBottom ? start.maxY : start.minY
            // Signed so that "positive" always means the same side as the start.
            var width = movesLeft ? anchorX - p.x : (movesRight ? p.x - anchorX : start.width)
            var height = movesBottom ? anchorY - p.y : (movesTop ? p.y - anchorY : start.height)

            if modifiers.contains(.shift), start.width > 0, start.height > 0 {
                let scale = max(abs(width) / start.width, abs(height) / start.height)
                width = start.width * scale * (width < 0 ? -1 : 1)
                height = start.height * scale * (height < 0 ? -1 : 1)
            }

            // A drag past the anchor mirrors the pixels rather than stopping.
            floatingFlippedX = floatingDragFlipX != (width < 0)
            floatingFlippedY = floatingDragFlipY != (height < 0)

            let spanX = movesLeft ? -width : width
            let spanY = movesBottom ? -height : height
            let x = min(anchorX, anchorX + spanX)
            let y = min(anchorY, anchorY + spanY)
            floatingFrame = CGRect(x: x.rounded(), y: y.rounded(),
                                   width: max(1, abs(width).rounded()),
                                   height: max(1, abs(height).rounded()))
        }
        moveFloatingSelection()
    }

    /// Keeps the selection outline on top of the floating pixels as they move.
    private func moveFloatingSelection() {
        guard floatingImage != nil else { return }
        doc.selectionPath = floatingOutline()
        doc.onChange?()
    }

    /// Draws the floating pixels into the layer. Whatever hangs off the canvas
    /// is clipped away at this point, which is why it waits until now.
    @discardableResult
    func commitFloatingPixels() -> Bool {
        guard let img = floatingImage else { return false }
        // A group holds no pixels: keep them floating rather than dropping
        // them into a bitmap nothing composites.
        guard let layer = doc.selectedRasterLayer else {
            onStatus?("That is a group — select a layer inside it to drop these pixels")
            return false
        }
        layer.context.saveGState()
        // Unscaled pixels are copied as they are; only a resize resamples.
        // A turn resamples whatever the size says, so only upright, unscaled
        // pixels get the straight copy.
        layer.context.interpolationQuality = floatingIsUnscaled && floatingAngle == 0
            ? .none : settings.resampling.quality
        drawFloating(img, in: layer.rawContext)
        layer.rawContext.restoreGState()
        removeFloatingOverlay()
        doc.selectionPath = floatingOutline()
        floatingImage = nil
        floatingUndoSnapshot = nil
        floatingStartSelection = nil
        floatingFrame = .zero
        doc.commit(floatingTitle)
        onNeedsDisplay?()
        return true
    }

    /// The knob that turns the floating pixels, on a stalk off the top edge.
    private func drawRotationKnob(in ctx: CGContext, scale: CGFloat) {
        guard let knob = floatingRotationKnob() else { return }
        let top = CGPoint(x: floatingFrame.midX, y: floatingFrame.maxY).applying(floatingTransform)
        ctx.saveGState()
        ctx.setLineWidth(1 / scale)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.move(to: top); ctx.addLine(to: knob); ctx.strokePath()
        let r = 4 / scale
        let box = CGRect(x: knob.x - r, y: knob.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: box)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.strokeEllipse(in: box)
        ctx.restoreGState()
    }

    /// A direction line with a knob at each end, drawn dark-on-light so it
    /// stays readable over whatever is on the canvas.
    private func drawGuide(_ path: CGPath, in ctx: CGContext, scale: CGFloat) {
        let points = path.linePoints
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(3 / scale)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.addPath(path); ctx.strokePath()
        ctx.setLineWidth(1 / scale)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.addPath(path); ctx.strokePath()
        let r = 3.5 / scale
        for (i, p) in points.enumerated() {
            let box = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(i == 0 ? NSColor.white.cgColor : NSColor.black.cgColor)
            ctx.fillEllipse(in: box)
            ctx.setLineWidth(1 / scale)
            ctx.setStrokeColor(i == 0 ? NSColor.black.cgColor : NSColor.white.cgColor)
            ctx.strokeEllipse(in: box)
        }
        ctx.restoreGState()
    }

    /// Draws the floating pixels, mirroring them if a resize crossed an edge.
    private func drawFloating(_ image: CGImage, in ctx: CGContext) {
        ctx.saveGState()
        if floatingAngle != 0 {
            let c = floatingCentre(floatingFrame)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: floatingAngle)
            ctx.translateBy(x: -c.x, y: -c.y)
        }
        if floatingFlippedX || floatingFlippedY {
            ctx.translateBy(x: floatingFrame.midX, y: floatingFrame.midY)
            ctx.scaleBy(x: floatingFlippedX ? -1 : 1, y: floatingFlippedY ? -1 : 1)
            ctx.translateBy(x: -floatingFrame.midX, y: -floatingFrame.midY)
        }
        ctx.draw(image, in: floatingFrame)
        ctx.restoreGState()
    }

    /// Arrow-key nudging while pixels are floating.
    func nudgeFloatingPixels(dx: CGFloat, dy: CGFloat) {
        guard floatingImage != nil else { return }
        floatingFrame = floatingFrame.offsetBy(dx: dx, dy: dy)
        moveFloatingSelection()
        onNeedsDisplay?()
    }

    /// Drops a paste, or puts lifted pixels back where they came from.
    func cancelFloatingPixels() {
        guard floatingImage != nil else { return }
        if let snapshot = floatingUndoSnapshot, let layer = doc.selectedRasterLayer {
            layer.restore(from: snapshot)
        }
        doc.selectionPath = floatingStartSelection
        floatingImage = nil
        floatingUndoSnapshot = nil
        floatingFrame = .zero
        removeFloatingOverlay()
        doc.onChange?()
        onNeedsDisplay?()
    }

    /// Handles on the selection outline, for the move/resize tools.
    private func drawSelectionHandles(in ctx: CGContext, scale: CGFloat) {
        drawHandles(selectionHandles(), in: ctx, scale: scale)
    }

    private func drawHandles(_ handles: [CGPoint], in ctx: CGContext, scale: CGFloat) {
        guard !handles.isEmpty else { return }
        let size = 7 / scale
        ctx.saveGState()
        ctx.setLineWidth(1 / scale)
        for handle in handles {
            let r = CGRect(x: handle.x - size / 2, y: handle.y - size / 2, width: size, height: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    /// Bounding box and handles for the pending shape.
    private func drawSessionChrome(_ s: ShapeSession, in ctx: CGContext, scale: CGFloat) {
        let t = transform(for: s)
        ctx.saveGState()
        ctx.setLineWidth(1 / scale)
        if !s.isLine {
            var tt = t
            let box = CGPath(rect: s.rect, transform: &tt)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addPath(box); ctx.strokePath()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4 / scale, 4 / scale])
            ctx.addPath(box); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let size = 7 / scale
        for h in sessionHandles(s) {
            let r = CGRect(x: h.x - size / 2, y: h.y - size / 2, width: size, height: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.stroke(r)
        }
        ctx.restoreGState()
    }

    /// Canvas overlay: preview geometry plus any floating pixels mid-drag.
    func drawOverlay(in ctx: CGContext, scale: CGFloat) {
        if let scratch = strokeScratch, let image = scratch.image {
            ctx.saveGState()
            ctx.setBlendMode(settings.blendMode.cgBlendMode)
            if let sel = doc.selectionPath { ctx.addPath(sel); ctx.clip(using: .evenOdd) }
            ctx.draw(image, in: strokeScratchRect)
            ctx.restoreGState()
        }
        if settings.tool == .moveSelection && floatingImage == nil {
            drawSelectionHandles(in: ctx, scale: scale)
        }
        if floatingImage != nil {
            // The pixels themselves are composited in their layer's place;
            // only the chrome belongs on top.
            drawHandles(floatingHandles(), in: ctx, scale: scale)
            drawRotationKnob(in: ctx, scale: scale)
        }
        if let s = session {
            let path = sessionPath(s)
            ctx.saveGState()
            renderShape(path, in: ctx, bounds: doc.bounds)
            ctx.restoreGState()
            drawSessionChrome(s, in: ctx, scale: scale)
        }
        guard let path = previewPath else { return }
        if previewStyle == .guide {
            drawGuide(path, in: ctx, scale: scale)
            return
        }
        if previewStyle == .selection {
            ctx.saveGState()
            ctx.setLineWidth(1 / scale)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4 / scale, 4 / scale])
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        } else {
            ctx.saveGState()
            renderShape(path, in: ctx, bounds: doc.bounds)
            ctx.restoreGState()
        }
    }
}

extension CGPath {
    /// The points of a straight two-point path, for drawing its end knobs.
    var linePoints: [CGPoint] {
        var points: [CGPoint] = []
        applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
            default: break
            }
        }
        return points
    }
}
