import AppKit
import CoreGraphics

/// A single raster layer. Pixels live in a premultiplied BGRA8 bitmap context
/// so tools can both draw with Core Graphics and poke individual pixels.
typealias LayerID = Int

final class Layer {
    private static var nextID = 0
    /// Identity that survives undo, so a snapshot can say "these are the same
    /// pixels as the step before" about the right layer.
    let id: LayerID
    /// A group holds no pixels of its own: it composites the layers nested
    /// under it as a unit so one opacity or blend mode covers the lot.
    enum Kind {
        case raster, group
    }

    let width: Int
    let height: Int
    var name: String
    var isVisible: Bool = true
    var opacity: CGFloat = 1.0
    var blendMode: LayerBlendMode = .normal
    var kind: Kind = .raster
    /// How deep this entry sits in the stack: 0 is top level, 1 is inside one
    /// group, and so on. The layer list stays flat and reads its nesting from
    /// this, the way the Layers palette draws it.
    var depth: Int = 0
    /// Whether a group hides its members in the palette. Purely presentation.
    var isCollapsed: Bool = false

    var isGroup: Bool { kind == .group }

    /// The bitmap, allocated the first time something draws into it. Groups
    /// never touch it, so a folder costs no memory.
    private var storage: CGContext?

    init(width: Int, height: Int, name: String, kind: Kind = .raster, depth: Int = 0,
         id: LayerID? = nil) {
        if let id {
            self.id = id
        } else {
            Layer.nextID += 1
            self.id = Layer.nextID
        }
        self.width = max(1, width)
        self.height = max(1, height)
        self.name = name
        self.kind = kind
        self.depth = depth
    }

    /// Bumped whenever anything draws into this layer. Undo snapshots and the
    /// thumbnail use it to tell "same pixels as last time" from "redraw me".
    private(set) var contentVersion: Int = 0
    /// Union of what has been drawn into since the last commit, when the
    /// callers said. Nil means "somewhere, but nobody said where", which is
    /// read as the whole layer.
    private(set) var dirtyRect: CGRect?
    private var dirtyIsWhole = true

    /// Drawing goes through here, and asking for it counts as an edit — a
    /// caller that only wants to read the pixels uses `image` or `pixels`.
    var context: CGContext {
        markEdited()
        return bitmap
    }

    /// Whether anything has ever been drawn into this layer.
    var hasPixels: Bool { storage != nil }

    /// The bitmap for a caller that has already said what it is about to
    /// change, through `markEdited`.
    var rawContext: CGContext { bitmap }

    /// The bitmap without claiming an edit.
    private var bitmap: CGContext {
        if let storage { return storage }
        let ctx = Layer.makeContext(width: width, height: height)
        storage = ctx
        return ctx
    }

    /// Notes that the pixels changed. Pass the rectangle when it is known: an
    /// undo step then only has to keep that much of the layer.
    func markEdited(_ rect: CGRect? = nil) {
        contentVersion &+= 1
        cachedThumbnail = nil
        guard let rect else {
            dirtyIsWhole = true
            dirtyRect = nil
            scaledPending = nil
            scaledPendingIsWhole = true
            return
        }
        if !scaledPendingIsWhole {
            let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            if !clipped.isEmpty {
                scaledPending = scaledPending.map { $0.union(clipped) } ?? clipped
            }
        }
        guard !dirtyIsWhole else { return }
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isEmpty else { return }
        dirtyRect = dirtyRect.map { $0.union(clipped) } ?? clipped
    }

    /// Draws into the layer, saying which rectangle is about to change. The
    /// undo step then only keeps that much instead of the whole canvas.
    func edit(_ rect: CGRect?, _ body: (CGContext) -> Void) {
        markEdited(rect)
        body(bitmap)
    }

    /// Raw pixel access for a write whose extent is known.
    func editPixels(_ rect: CGRect?) -> UnsafeMutablePointer<UInt8>? {
        markEdited(rect)
        return bitmap.data?.assumingMemoryBound(to: UInt8.self)
    }

    /// Called once the current state has been recorded, so the next edit
    /// starts a fresh region.
    func clearDirtyRegion() {
        dirtyIsWhole = false
        dirtyRect = nil
    }

    /// What an undo step has to keep for this layer: nil when the whole thing
    /// has to be copied.
    var dirtyRegion: CGRect? { dirtyIsWhole ? nil : dirtyRect }

    static func makeContext(width: Int, height: Int) -> CGContext {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            fatalError("Could not allocate a \(width)x\(height) bitmap")
        }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        return ctx
    }

    var image: CGImage? {
        guard !isGroup else { return nil }
        return bitmap.makeImage()
    }

    /// Raw pixel access for writing (BGRA order, premultiplied).
    var data: UnsafeMutablePointer<UInt8>? {
        markEdited()
        return bitmap.data?.assumingMemoryBound(to: UInt8.self)
    }

    /// The same buffer, for callers that only read it.
    var pixels: UnsafeMutablePointer<UInt8>? {
        bitmap.data?.assumingMemoryBound(to: UInt8.self)
    }

    var bytesPerRow: Int { bitmap.bytesPerRow }

    func clear() {
        guard storage != nil else { return }
        markEdited()
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
    }

    func fill(with color: NSColor) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(color.srgb.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    func draw(image img: CGImage, in rect: CGRect? = nil) {
        let r = rect ?? CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(img, in: r)
    }

    /// Replace the whole bitmap with a snapshot (used by undo).
    func restore(from snapshot: CGImage?) {
        clear()
        if let snapshot { context.draw(snapshot, in: CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    func copyLayer(named newName: String? = nil) -> Layer {
        let l = Layer(width: width, height: height, name: newName ?? "\(name) copy",
                      kind: kind, depth: depth)
        if let img = image { l.draw(image: img) }
        l.isVisible = isVisible
        l.opacity = opacity
        l.blendMode = blendMode
        l.isCollapsed = isCollapsed
        return l
    }

    /// An empty layer of a different size carrying this one's settings, for
    /// the document commands that rebuild the whole stack.
    func emptyCopy(width: Int, height: Int) -> Layer {
        let l = Layer(width: width, height: height, name: name, kind: kind, depth: depth)
        l.isVisible = isVisible
        l.opacity = opacity
        l.blendMode = blendMode
        l.isCollapsed = isCollapsed
        return l
    }

    private var cachedThumbnail: (key: String, image: NSImage)?

    func thumbnail(size: NSSize) -> NSImage {
        let key = "\(Int(size.width))x\(Int(size.height))-\(contentVersion)"
        if let cached = cachedThumbnail, cached.key == key { return cached.image }

        let image = NSImage(size: size)
        image.lockFocus()
        drawCheckerboard(in: NSRect(origin: .zero, size: size), cell: 4)
        if let full = self.image, let small = Layer.downsampled(full, fitting: size) {
            NSBitmapImageRep(cgImage: small).draw(in: NSRect(origin: .zero, size: size),
                                                  from: .zero,
                                                  operation: .sourceOver,
                                                  fraction: 1,
                                                  respectFlipped: true,
                                                  hints: nil)
        }
        image.unlockFocus()
        cachedThumbnail = (key, image)
        return image
    }

    // MARK: - Zoomed-out copy

    private var scaledContext: CGContext?
    private var scaledLevel = 0
    private var scaledVersion = -1
    /// What the shrunk copy still has to catch up on. Kept apart from the undo
    /// region, which is cleared on every commit.
    private var scaledPending: CGRect?
    private var scaledPendingIsWhole = true

    /// A copy of the layer suited to drawing at `scale`, so a zoomed-out view
    /// does not resample every pixel of a huge canvas on every redraw. Levels
    /// are halvings; anything at half size or larger uses the layer itself.
    func image(forScale scale: CGFloat) -> CGImage? {
        guard !isGroup else { return nil }
        guard scale > 0, scale < 0.5, min(width, height) > 64 else { return image }

        let level = max(1, min(12, Int(log2(1 / scale).rounded(.down))))
        let scaledWidth = max(1, width >> level)
        let scaledHeight = max(1, height >> level)

        if scaledLevel != level || scaledContext == nil {
            let ctx = Layer.makeContext(width: scaledWidth, height: scaledHeight)
            ctx.interpolationQuality = .medium
            // The same two-step trick the thumbnails use: one cheap pass to a
            // middling size, then a good one, instead of a full-quality
            // resample of every pixel.
            if let full = image, let shrunk = Layer.downsampled(
                full, fitting: NSSize(width: scaledWidth, height: scaledHeight)) {
                ctx.draw(shrunk, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
            }
            scaledContext = ctx
            scaledLevel = level
            scaledVersion = contentVersion
            scaledPending = nil
            scaledPendingIsWhole = false
            return ctx.makeImage()
        }

        guard let ctx = scaledContext else { return image }
        if scaledVersion != contentVersion {
            // Only what changed has to be redrawn into the copy — that is what
            // keeps a stroke cheap while the whole canvas is on screen.
            let factor = CGFloat(scaledWidth) / CGFloat(width)
            let pending = scaledPendingIsWhole ? nil : scaledPending
            if let dirty = pending, !dirty.isEmpty, let full = image {
                let target = CGRect(x: dirty.minX * factor, y: dirty.minY * factor,
                                    width: dirty.width * factor, height: dirty.height * factor)
                    .insetBy(dx: -1, dy: -1)
                let source = CGRect(x: dirty.minX, y: CGFloat(height) - dirty.maxY,
                                    width: dirty.width, height: dirty.height)
                if let patch = full.cropping(to: source.integral) {
                    ctx.saveGState()
                    ctx.clear(target)
                    ctx.interpolationQuality = .medium
                    ctx.draw(patch, in: target)
                    ctx.restoreGState()
                }
            } else if let full = image {
                ctx.clear(CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
                ctx.interpolationQuality = .medium
                ctx.draw(full, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
            }
            scaledVersion = contentVersion
            scaledPending = nil
            scaledPendingIsWhole = false
        }
        return ctx.makeImage()
    }

    /// Shrinks in two steps. Asking Core Graphics to go from a huge bitmap
    /// straight to a 34-pixel square costs it a full high-quality resample of
    /// every pixel; a cheap pass to a middling size first is ~100x faster and
    /// looks the same at this scale.
    static func downsampled(_ image: CGImage, fitting size: NSSize) -> CGImage? {
        let target = max(1, Int(max(size.width, size.height).rounded()))
        let longest = max(image.width, image.height)
        guard longest > target else { return image }

        var source = image
        if longest > target * 8 {
            // The middle size has to stay above the target, or the second pass
            // is scaling a blurry image back up.
            let step = max(target * 4, 64)
            let stepWidth = max(1, image.width * step / longest)
            let stepHeight = max(1, image.height * step / longest)
            let ctx = Layer.makeContext(width: stepWidth, height: stepHeight)
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: stepWidth, height: stepHeight))
            source = ctx.makeImage() ?? image
        }
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let ctx = Layer.makeContext(width: width, height: height)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

}

func drawCheckerboard(in rect: NSRect, cell: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    // Only the part that can actually be seen is worth walking: zoomed in far
    // enough, the full rect is millions of squares and drawing them all takes
    // minutes and gigabytes.
    let clip = ctx.boundingBoxOfClipPath
    let visible = clip.isNull ? rect : rect.intersection(clip)
    guard !visible.isNull, !visible.isEmpty, cell > 0 else { return }

    ctx.saveGState()
    ctx.clip(to: rect)
    ctx.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
    ctx.fill(visible)
    ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)

    // Squares are laid out from the rect's own corner, so the pattern does not
    // shift when only part of it is drawn.
    let firstRow = Int(((visible.minY - rect.minY) / cell).rounded(.down))
    let lastRow = Int(((visible.maxY - rect.minY) / cell).rounded(.up))
    let firstColumn = Int(((visible.minX - rect.minX) / (cell * 2)).rounded(.down))
    let lastColumn = Int(((visible.maxX - rect.minX) / (cell * 2)).rounded(.up))
    guard lastRow >= firstRow, lastColumn >= firstColumn else { ctx.restoreGState(); return }

    for row in firstRow...lastRow {
        let y = rect.minY + CGFloat(row) * cell
        let offset = row % 2 == 0 ? 0 : cell
        for column in firstColumn...lastColumn {
            let x = rect.minX + CGFloat(column) * cell * 2 + offset
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
    ctx.restoreGState()
}
