import AppKit
import CoreGraphics

/// A single raster layer. Pixels live in a premultiplied BGRA8 bitmap context
/// so tools can both draw with Core Graphics and poke individual pixels.
final class Layer {
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

    init(width: Int, height: Int, name: String, kind: Kind = .raster, depth: Int = 0) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.name = name
        self.kind = kind
        self.depth = depth
    }

    var context: CGContext {
        if let storage { return storage }
        let ctx = Layer.makeContext(width: width, height: height)
        storage = ctx
        return ctx
    }

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
        return context.makeImage()
    }

    /// Raw pixel access (BGRA order, premultiplied).
    var data: UnsafeMutablePointer<UInt8>? {
        context.data?.assumingMemoryBound(to: UInt8.self)
    }

    var bytesPerRow: Int { context.bytesPerRow }

    func clear() {
        guard storage != nil else { return }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
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

    func thumbnail(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        drawCheckerboard(in: NSRect(origin: .zero, size: size), cell: 4)
        if let cg = image {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.draw(in: NSRect(origin: .zero, size: size),
                     from: .zero,
                     operation: .sourceOver,
                     fraction: 1,
                     respectFlipped: true,
                     hints: nil)
        }
        img.unlockFocus()
        return img
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
