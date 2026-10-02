import AppKit
@testable import SketchyKit

// Minimal harness: `swift run SketchySelfTest` exits non-zero if anything fails.
var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL  \(message)\n".utf8))
    }
}

func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) — got \(a), expected \(b)")
}

func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat, _ message: String) {
    check(abs(a - b) <= tolerance, "\(message) — got \(a), expected \(b) ± \(tolerance)")
}

func pixel(_ doc: Document, _ x: Int, _ y: Int) -> PixelOps.RGBA? {
    guard let img = doc.composite() else { return nil }
    let l = Layer(width: img.width, height: img.height, name: "probe")
    l.draw(image: img)
    return PixelOps.sample(l, x: x, y: y)
}

func section(_ name: String) { print("• \(name)") }

/// Windows and panels need a window server, which a headless CI shell lacks.
let hasWindowServer = CGSessionCopyCurrentDictionary() != nil

func windowSection(_ name: String, _ body: () -> Void) {
    guard hasWindowServer else {
        print("• \(name) (skipped: no window server)")
        return
    }
    section(name)
    body()
}

// MARK: - New document

section("new document")
do {
    let doc = Document(width: 32, height: 16)
    equal(doc.width, 32, "document width")
    equal(doc.layers.count, 1, "layer count")
    let p = pixel(doc, 4, 4)
    equal(p?.r ?? 0, 255, "background is white")
    equal(p?.a ?? 0, 255, "background is opaque")
}

// MARK: - Painting and undo

section("pencil stroke, undo and redo")
do {
    let doc = Document(width: 32, height: 32)
    let settings = ToolSettings()
    settings.tool = .pencil
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red
    engine.mouseDown(at: CGPoint(x: 4, y: 4), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 20, y: 4), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 20, y: 4), modifiers: [])

    let sketchy = pixel(doc, 12, 4)
    equal(sketchy?.r ?? 0, 255, "stroke is red")
    check(Int(sketchy?.g ?? 255) < 40, "stroke removed green channel")

    check(doc.undo(), "undo succeeded")
    equal(pixel(doc, 12, 4)?.g ?? 0, 255, "undo restored white")
    check(doc.redo(), "redo succeeded")
    check(Int(pixel(doc, 12, 4)?.g ?? 255) < 40, "redo repainted")
}

// MARK: - Paint bucket

section("paint bucket")
do {
    let doc = Document(width: 24, height: 24)
    let settings = ToolSettings()
    settings.tool = .paintBucket
    settings.tolerance = 0.1
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .blue
    engine.mouseDown(at: CGPoint(x: 12, y: 12), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 12, y: 12), modifiers: [])
    let p = pixel(doc, 1, 1)
    equal(p?.b ?? 0, 255, "flood filled the whole canvas")
    check(Int(p?.r ?? 255) < 40, "red channel cleared")
}

// MARK: - Selection clipping

section("selection clips painting")
do {
    let doc = Document(width: 32, height: 32)
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 8, height: 32), transform: nil)
    let settings = ToolSettings()
    settings.tool = .pencil
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red
    engine.mouseDown(at: CGPoint(x: 2, y: 16), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 30, y: 16), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 30, y: 16), modifiers: [])
    check(Int(pixel(doc, 4, 16)?.g ?? 255) < 40, "inside the selection is sketchy")
    equal(pixel(doc, 20, 16)?.g ?? 0, 255, "outside the selection is untouched")
}

// MARK: - Layers

section("layer stack")
do {
    let doc = Document(width: 8, height: 8)
    doc.addLayer()
    equal(doc.layers.count, 2, "added a layer")
    doc.duplicateSelectedLayer()
    equal(doc.layers.count, 3, "duplicated a layer")
    doc.mergeLayerDown()
    equal(doc.layers.count, 2, "merged down")
    doc.deleteSelectedLayer()
    equal(doc.layers.count, 1, "deleted a layer")
    doc.deleteSelectedLayer()
    equal(doc.layers.count, 1, "the last layer is kept")
}

section("opacity affects the composite")
do {
    let doc = Document(width: 8, height: 8)
    doc.addLayer()
    doc.selectedLayer?.fill(with: .black)
    doc.selectedLayer?.opacity = 0.5
    let p = pixel(doc, 4, 4)
    check(p != nil && p!.r > 100 && p!.r < 160, "half-opacity black over white is mid grey")
}

// MARK: - Geometry

section("canvas geometry")
do {
    let doc = Document(width: 20, height: 10)
    doc.rotate(turns: 1)
    equal(doc.width, 10, "rotate swapped width")
    equal(doc.height, 20, "rotate swapped height")
    doc.resizeImage(to: CGSize(width: 5, height: 5))
    equal(doc.width, 5, "resized image")
    doc.resizeCanvas(to: CGSize(width: 9, height: 9))
    equal(doc.height, 9, "resized canvas")
}

// MARK: - Shapes

section("shape geometry")
do {
    let r = CGRect(x: 0, y: 0, width: 100, height: 60)
    for kind in ShapeKind.allCases {
        let path = ShapeFactory.path(for: kind, in: r)
        check(!path.isEmpty, "\(kind.rawValue) has geometry")
        check(r.insetBy(dx: -1, dy: -1).contains(path.boundingBoxOfPath),
              "\(kind.rawValue) stays inside its bounds")
    }
}

// MARK: - File round trip

section("save and reopen")
do {
    let doc = Document(width: 16, height: 12)
    doc.selectedLayer?.fill(with: .green)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sketchy-selftest-\(UUID().uuidString).png")
    do {
        try doc.write(to: url)
        let reopened = try Document.open(url: url)
        equal(reopened.width, 16, "reopened width")
        equal(reopened.height, 12, "reopened height")
        equal(pixel(reopened, 8, 6)?.g ?? 0, 255, "reopened pixels survived")
    } catch {
        check(false, "round trip threw \(error)")
    }
    try? FileManager.default.removeItem(at: url)
}

// MARK: - History

section("history navigation")
do {
    let doc = Document(width: 8, height: 8)
    for _ in 0..<5 { doc.addLayer() }
    equal(doc.history.entries.count, 6, "history recorded every step")
    doc.jumpHistory(to: 0)
    equal(doc.layers.count, 1, "jumped back to the start")
    doc.jumpHistory(to: 5)
    equal(doc.layers.count, 6, "jumped forward again")
}

// MARK: - Magic wand

section("magic wand")
do {
    let doc = Document(width: 16, height: 16)
    doc.selectedLayer?.context.setFillColor(NSColor.black.cgColor)
    doc.selectedLayer?.context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
    let settings = ToolSettings()
    settings.tool = .magicWand
    settings.tolerance = 0.05
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.mouseDown(at: CGPoint(x: 2, y: 8), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 2, y: 8), modifiers: [])
    if let box = doc.selectionPath?.boundingBoxOfPath {
        near(box.width, 8, 1, "wand selected the black half's width")
        near(box.height, 16, 1, "wand selected the full height")
    } else {
        check(false, "wand produced a selection")
    }
}

// MARK: - Effects

section("adjustments")
do {
    let doc = Document(width: 16, height: 16)
    doc.selectedLayer?.fill(with: NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    let ok = ImageEffects.apply(ImageEffects.invert, to: doc.selectedLayer!, selection: nil)
    check(ok, "invert applied")
    if let p = pixel(doc, 8, 8) {
        check(p.r > 180 && p.b < 80, "colors were inverted (got r=\(p.r) g=\(p.g) b=\(p.b) a=\(p.a))")
    }
}

// MARK: - Native .ptd round trip

section("native .ptd document")
do {
    let doc = Document(width: 20, height: 14)
    doc.selectedLayer?.fill(with: .red)
    doc.addLayer(named: "Top")
    doc.selectedLayer?.fill(with: .blue)
    doc.selectedLayer?.opacity = 0.4
    doc.selectedLayer?.blendMode = .multiply
    doc.layers[0].isVisible = true

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sketchy-selftest-\(UUID().uuidString).sketchy")
    do {
        try doc.write(to: url)
        let reopened = try Document.open(url: url)
        equal(reopened.layers.count, 2, "layers survived the round trip")
        equal(reopened.width, 20, "width survived")
        equal(reopened.layers[1].name, "Top", "layer name survived")
        equal(reopened.layers[1].blendMode, .multiply, "blend mode survived")
        near(reopened.layers[1].opacity, 0.4, 0.01, "opacity survived")
        let base = PixelOps.sample(reopened.layers[0], x: 10, y: 7)
        equal(base?.r ?? 0, 255, "bottom layer pixels survived")
    } catch {
        check(false, "native round trip threw \(error)")
    }
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Shape sessions

section("editable shape session")
do {
    let doc = Document(width: 100, height: 100)
    let settings = ToolSettings()
    settings.tool = .shapes
    settings.shape = .rectangle
    settings.drawMode = .fill
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .black
    engine.secondaryColor = .red

    engine.mouseDown(at: CGPoint(x: 10, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 40, y: 30), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 40, y: 30), modifiers: [])

    check(engine.session != nil, "the shape stays editable after the drag")
    equal(pixel(doc, 25, 20)?.r ?? 0, 255, "nothing is rasterized yet")

    // Drag from inside to move it.
    engine.mouseDown(at: CGPoint(x: 25, y: 20), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 65, y: 60), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 65, y: 60), modifiers: [])
    if let s = engine.session {
        near(s.center.x, 65, 1, "moved horizontally")
        near(s.center.y, 60, 1, "moved vertically")
    } else {
        check(false, "session survived the move")
    }

    // Drag outside the box to rotate it.
    let before = engine.session?.angle ?? 0
    engine.mouseDown(at: CGPoint(x: 95, y: 60), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 65, y: 90), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 65, y: 90), modifiers: [])
    near(abs((engine.session?.angle ?? 0) - before), .pi / 2, 0.2, "rotated a quarter turn")

    let steps = doc.history.entries.count
    check(engine.commitSession(), "commit rasterized the shape")
    check(engine.session == nil, "session cleared after commit")
    equal(doc.history.entries.count, steps + 1, "commit pushed one history step")
    // A filled shape uses the secondary color (red) for its interior.
    let fillPixel = pixel(doc, 65, 60)
    equal(fillPixel?.r ?? 0, 255, "shape interior is the secondary color")
    check(Int(fillPixel?.b ?? 255) < 40, "pixels landed where the shape was")
}

section("scroll wheel adjusts the tool")
do {
    let settings = ToolSettings()

    settings.tool = .paintbrush
    settings.brushWidth = 10
    equal(settings.adjustable(secondary: false), ToolSettings.Adjustable.size, "brush scrolls its size")
    settings.adjust(.size, steps: 4)
    equal(settings.brushWidth, 14, "four notches up, four pixels wider")
    settings.adjust(.size, steps: -100)
    equal(settings.brushWidth, 1, "and it stops at one pixel")

    equal(settings.adjustable(secondary: true), ToolSettings.Adjustable.hardness,
          "shift reaches the brush's second dial")

    settings.tool = .paintBucket
    settings.tolerance = 0.3
    equal(settings.adjustable(secondary: false), ToolSettings.Adjustable.tolerance,
          "the bucket scrolls tolerance")
    check(settings.adjustable(secondary: true) == nil, "and has nothing on shift")
    settings.adjust(.tolerance, steps: 5)
    near(settings.tolerance, 0.35, 0.001, "five notches is five percent")
    settings.adjust(.tolerance, steps: 500)
    equal(settings.tolerance, 1, "tolerance tops out at 100%")

    settings.tool = .gradient
    equal(settings.adjustable(secondary: false), ToolSettings.Adjustable.strength,
          "the gradient scrolls its strength")
    settings.adjust(.strength, steps: -10)
    near(settings.gradientStrength, 0.5, 0.001, "ten notches down is half strength")

    settings.tool = .magicWand
    equal(settings.adjustable(secondary: false), ToolSettings.Adjustable.tolerance,
          "the wand shares the bucket's dial")
    settings.tool = .pan
    check(settings.adjustable(secondary: false) == nil, "tools without a dial ignore the wheel")

    // The readout the status bar shows.
    settings.tool = .paintbrush
    settings.brushWidth = 7
    equal(settings.adjust(.size, steps: 1), "Size 8", "the change is reported back")
}

section("gradient strength")
do {
    let doc = Document(width: 20, height: 20, background: nil)
    let settings = ToolSettings()
    settings.tool = .gradient
    settings.gradientStrength = 0.5
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .white
    engine.secondaryColor = .white

    engine.mouseDown(at: CGPoint(x: 0, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 19, y: 10), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 19, y: 10), modifiers: [])

    let a = pixel(doc, 10, 10)?.a ?? 0
    check(a > 100 && a < 160, "half strength lands half-opaque, got \(a)")
}

section("gradient drag shows its direction")
do {
    let doc = Document(width: 40, height: 40, background: nil)
    let settings = ToolSettings()
    settings.tool = .gradient
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .white
    engine.secondaryColor = .black

    engine.mouseDown(at: CGPoint(x: 5, y: 5), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 30, y: 20), modifiers: [])

    let preview = engine.previewPath ?? CGMutablePath()
    check(engine.previewPath != nil, "the drag previews something")
    equal(engine.previewStyle, ToolEngine.PreviewStyle.guide, "a gradient previews a guide, not a shape")
    equal(preview.linePoints.count, 2, "the guide is a two-point line")
    equal(preview.linePoints.first ?? .zero, CGPoint(x: 5, y: 5), "running from where the drag started")
    equal(preview.linePoints.last ?? .zero, CGPoint(x: 30, y: 20), "to where the pointer is")
    check(preview.boundingBoxOfPath.width > 0 && preview.boundingBoxOfPath.height > 0,
          "and it is not collapsed")

    engine.mouseUp(at: CGPoint(x: 30, y: 20), modifiers: [])
    check(engine.previewPath == nil, "the guide goes away once the gradient is drawn")
    equal(doc.history.currentTitle, "Gradient", "and the gradient is what landed")
}

section("shapes mirror when a drag crosses over")
do {
    let doc = Document(width: 100, height: 100)
    let settings = ToolSettings()
    settings.tool = .shapes
    settings.shape = .triangle          // asymmetric, so a flip is visible
    settings.drawMode = .fill
    let engine = ToolEngine(doc: doc, settings: settings)

    // Draw upwards: apex at the top.
    engine.mouseDown(at: CGPoint(x: 20, y: 20), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 60, y: 60), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 60, y: 60), modifiers: [])
    check(!(engine.session?.flipY ?? true), "dragging up leaves the shape upright")

    // Drag the top edge down past the bottom: the triangle turns over instead
    // of sliding down the canvas.
    let box = engine.session!.rect
    engine.mouseDown(at: CGPoint(x: box.midX, y: box.maxY), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: box.midX, y: box.minY - 30), modifiers: [])
    engine.mouseUp(at: CGPoint(x: box.midX, y: box.minY - 30), modifiers: [])

    let flipped = engine.session!
    check(flipped.flipY, "crossing the bottom edge mirrors it")
    check(!flipped.flipX, "and leaves the other axis alone")
    near(flipped.rect.maxY, box.minY, 1, "the box now hangs below where it was")
    near(flipped.rect.width, box.width, 1, "with its width untouched")

    // Dragging back over restores the original orientation, once, not per event.
    engine.mouseDown(at: CGPoint(x: box.midX, y: flipped.rect.minY), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: box.midX, y: box.minY - 10), modifiers: [])
    engine.mouseDragged(to: CGPoint(x: box.midX, y: box.maxY), modifiers: [])
    engine.mouseUp(at: CGPoint(x: box.midX, y: box.maxY), modifiers: [])
    check(!(engine.session?.flipY ?? true), "dragging back the other way flips it upright again")

    // The mirrored path is what gets drawn, not just a flag.
    var down = ToolEngine.ShapeSession(kind: .triangle, p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 10, y: 10))
    down.flipY = true
    let upright = ToolEngine.ShapeSession(kind: .triangle, p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 10, y: 10))
    let apexUp = engine.sessionPath(upright).boundingBoxOfPath
    let apexDown = engine.sessionPath(down).boundingBoxOfPath
    near(apexUp.height, apexDown.height, 0.01, "mirroring keeps the same bounds")
    let up = engine.sessionPath(upright), over = engine.sessionPath(down)
    check(up.contains(CGPoint(x: 1, y: 1)), "upright, the base fills the bottom corners")
    check(!up.contains(CGPoint(x: 1, y: 9)), "and the top corners are outside it")
    check(over.contains(CGPoint(x: 1, y: 9)), "mirrored, the base is at the top")
    check(!over.contains(CGPoint(x: 1, y: 1)), "and the bottom corners are outside")
}

section("shape session cancel")
do {
    let doc = Document(width: 60, height: 60)
    let settings = ToolSettings()
    settings.tool = .shapes
    settings.shape = .ellipse
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.mouseDown(at: CGPoint(x: 10, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 50, y: 50), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 50, y: 50), modifiers: [])
    engine.cancelSession()
    check(engine.session == nil, "cancel discards the shape")
    equal(pixel(doc, 30, 30)?.r ?? 0, 255, "canvas untouched after cancel")
}

// MARK: - Layer transform

section("rotate / zoom layer")
do {
    let doc = Document(width: 40, height: 40, background: nil)
    let layer = doc.selectedLayer!
    layer.context.setFillColor(NSColor.black.cgColor)
    layer.context.fill(CGRect(x: 0, y: 0, width: 40, height: 10))   // bar along the bottom
    doc.transformLayer(layer, angle: .pi / 2, scale: 1, offset: .zero)
    // +90° turns the bottom bar into a bar along the right edge.
    let right = PixelOps.sample(layer, x: 35, y: 20)
    let bottom = PixelOps.sample(layer, x: 20, y: 5)
    check((right?.a ?? 0) > 200, "the bar rotated onto its side")
    check((bottom?.a ?? 255) < 60, "the original position is now empty")
}

// MARK: - Erase

section("delete key erases")
do {
    let doc = Document(width: 40, height: 40)
    doc.selectedLayer?.fill(with: .black)

    // With a selection, only that region is cleared.
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 40), transform: nil)
    check(doc.eraseSelection(), "erase reported success")
    check(Int(PixelOps.sample(doc.selectedLayer!, x: 5, y: 20)?.a ?? 255) < 20, "selected region is transparent")
    equal(PixelOps.sample(doc.selectedLayer!, x: 30, y: 20)?.a ?? 0, 255, "the rest is untouched")
    equal(doc.history.currentTitle, "Erase Selection", "history names the selection erase")

    // With nothing selected, the whole layer goes.
    doc.deselect()
    doc.eraseSelection()
    check(Int(PixelOps.sample(doc.selectedLayer!, x: 30, y: 20)?.a ?? 255) < 20, "whole layer cleared")
    equal(doc.history.currentTitle, "Erase Layer", "history names the layer erase")

    check(doc.undo(), "erase is undoable")
    equal(PixelOps.sample(doc.selectedLayer!, x: 30, y: 20)?.a ?? 0, 255, "undo brought the pixels back")
}

// MARK: - Responsive palettes

section("palette content reflows")
do {
    let tools = ToolsPaletteView(frame: NSRect(x: 0, y: 0, width: 84, height: 340))
    let twoCol = tools.preferredHeight(forWidth: 84) ?? 0
    let oneCol = tools.preferredHeight(forWidth: 44) ?? 0
    let wide = tools.preferredHeight(forWidth: 300) ?? 0
    check(oneCol > twoCol, "one column is taller than two")
    check(wide < twoCol, "a wide rail packs the tools into fewer rows")

    // Buttons must actually move, not just the reported height.
    tools.setFrameSize(NSSize(width: 44, height: oneCol))
    let narrowXs = Set(tools.subviews.map { Int($0.frame.minX) })
    tools.setFrameSize(NSSize(width: 300, height: wide))
    let wideXs = Set(tools.subviews.map { Int($0.frame.minX) })
    equal(narrowXs.count, 1, "one column of buttons when narrow")
    check(wideXs.count > 4, "many columns when wide")
    check(tools.subviews.allSatisfy { $0.frame.maxX <= 300 }, "buttons stay inside the view")

    let colors = ColorsPaletteView(frame: NSRect(x: 0, y: 0, width: 232, height: 380))
    let tall = colors.preferredHeight(forWidth: 232) ?? 0
    let short = colors.preferredHeight(forWidth: 110) ?? 0
    check(short < tall, "the color wheel shrinks with the rail")
    colors.setFrameSize(NSSize(width: 110, height: short))
    check(colors.wheel.frame.maxX <= 110, "the wheel fits the narrow width")
    check(colors.moreButton.isHidden, "More >> hides when there is no room")
    colors.setFrameSize(NSSize(width: 232, height: tall))
    check(!colors.moreButton.isHidden, "More >> comes back when there is room")
    check(colors.paletteView.frame.width > 180, "the swatch strip stretches")

    // The numeric fields wrap with the width and stay inside the palette.
    colors.setFrameSize(NSSize(width: 300, height: colors.preferredHeight(forWidth: 300) ?? 0))
    let wideRows = Set(colors.rgbaFields.map { Int($0.frame.minY) })
    equal(wideRows.count, 1, "R G B A share one row when there is room")
    check(colors.rgbaFields.allSatisfy { $0.frame.maxX <= 300 }, "fields stay inside the width")
    check(colors.hexField.frame.width > 200, "the hex field spans the palette")

    colors.setFrameSize(NSSize(width: 130, height: colors.preferredHeight(forWidth: 130) ?? 0))
    let narrowRows = Set(colors.rgbaFields.map { Int($0.frame.minY) })
    equal(narrowRows.count, 2, "R G B A wrap onto two rows when narrow")
    check(colors.rgbaFields.allSatisfy { $0.frame.maxX <= 130 }, "wrapped fields stay inside the width")
    // Nothing may overlap the swatch strip or the wheel above it.
    let lowestField = colors.hsvFields.map(\.frame.minY).min() ?? 0
    let highestField = colors.rgbaFields.map(\.frame.maxY).max() ?? 0
    check(lowestField > colors.paletteView.frame.maxY, "fields sit above the swatch strip")
    check(highestField < colors.wheel.frame.minY, "fields sit below the wheel")
}

windowSection("color fields drive the palette") {
    let panel = ColorsPanel()
    let fields = panel.palette

    func commit(_ field: NSTextField) {
        _ = field.target?.perform(field.action, with: field)
    }

    fields.hexField.stringValue = "#1E90FF"
    commit(fields.hexField)
    equal(panel.primary.hexString, "1E90FF", "typing hex sets the primary color")
    equal(fields.redField.integerValue, 30, "the R field follows the hex")
    equal(fields.blueField.integerValue, 255, "the B field follows the hex")

    fields.redField.integerValue = 10
    fields.greenField.integerValue = 20
    fields.blueField.integerValue = 30
    fields.alphaField.integerValue = 128
    commit(fields.redField)
    equal(panel.primary.hexString, "0A141E80", "RGBA entry sets the color, alpha included")

    fields.hueField.integerValue = 120
    fields.saturationField.integerValue = 100
    fields.valueField.integerValue = 100
    commit(fields.hueField)
    equal(panel.primary.rgbaBytes.g, 255, "HSV entry sets the color")

    // Garbage is rejected and the field snaps back to the current color.
    let before = panel.primary.hexString
    fields.hexField.stringValue = "zzz"
    commit(fields.hexField)
    equal(panel.primary.hexString, before, "invalid hex leaves the color alone")
    equal(fields.hexField.stringValue, before, "invalid hex is replaced by the current value")

    // Picking elsewhere refreshes the fields.
    panel.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), secondary: false)
    equal(fields.hexField.stringValue, "FF0000", "picking a color updates the fields")
    equal(fields.hueField.integerValue, 0, "red reads as hue 0")
}

// MARK: - Docking

windowSection("palette docking") {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    let manager = DockManager(window: window)
    window.contentView?.addSubview(manager.leftRail)
    window.contentView?.addSubview(manager.rightRail)

    let panel = FloatingPanel(title: "Layers", size: NSSize(width: 262, height: 360))
    _ = panel.contentView
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 262, height: 360))
    let marker = NSTextField(labelWithString: "layer list")
    content.addSubview(marker)
    panel.contentView = content
    let palette = Palette(id: "layers", title: "Layers", panel: panel, dockedHeight: nil)
    manager.register(palette)

    equal(palette.side, .floating, "palettes start floating")

    manager.dock(palette, to: .right)
    equal(palette.side, .right, "docked to the right rail")
    check(!manager.rightRail.isEmpty, "the rail holds a box")
    check(marker.window === window, "the palette's controls moved into the main window")
    check(!panel.isVisible, "the floating panel is hidden while docked")

    manager.dock(palette, to: .left)
    equal(palette.side, .left, "moved across to the left rail")
    check(manager.rightRail.isEmpty, "the old rail released it")
    equal(manager.leftRail.boxes.count, 1, "the new rail owns exactly one box")

    manager.float(palette)
    equal(palette.side, .floating, "torn back off into its panel")
    check(manager.leftRail.isEmpty, "the rail is empty again")
    check(marker.window === panel, "the controls returned to the panel")

    // A collapsed box shrinks to its header.
    manager.dock(palette, to: .left)
    if let box = palette.box {
        let expanded = box.fittingHeight(available: 400)
        box.isCollapsed = true
        equal(box.fittingHeight(available: 400), DockedPaletteBox.headerHeight, "collapsed to the header")
        check(expanded > DockedPaletteBox.headerHeight, "expanded is taller than collapsed")
    } else {
        check(false, "docking produced a box")
    }
    manager.resetLayout()
    equal(palette.side, .floating, "reset floats everything again")
}

// MARK: - Tabs share one set of palettes

windowSection("document commands land a floating paste first") {
    let hub = PaletteHub()
    let controller = MainWindowController(doc: Document(width: 40, height: 20), hub: hub)
    let doc = controller.doc

    let clip = Layer(width: 10, height: 10, name: "clip")
    clip.fill(with: .red)
    controller.selectTool(.moveSelectedPixels)
    controller.engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 5, y: 5))
    check(controller.engine.hasFloatingPixels, "the paste is floating")

    // Rotating rebuilds every layer from its bitmap, so a paste left hovering
    // would be thrown away.
    controller.rotate90CW(nil)
    check(!controller.engine.hasFloatingPixels, "rotating landed the paste")
    equal(doc.width, 20, "the canvas rotated")
    equal(doc.height, 40, "both ways")

    let landed = doc.composite().map { image -> Bool in
        let probe = Layer(width: image.width, height: image.height, name: "probe")
        probe.draw(image: image)
        for y in 0..<image.height {
            for x in 0..<image.width {
                if let p = PixelOps.sample(probe, x: x, y: y), p.r > 200, p.g < 60, p.b < 60 {
                    return true
                }
            }
        }
        return false
    } ?? false
    check(landed, "the pasted pixels are still in the document after the rotation")

    // The same guard covers the other document-wide commands.
    controller.engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 2, y: 2))
    controller.flattenImage(nil)
    check(!controller.engine.hasFloatingPixels, "flattening landed it too")
}

windowSection("palettes stay out of the way") {
    let hub = PaletteHub()
    let panels = [hub.toolsPanel, hub.colorsPanel, hub.historyPanel, hub.layersPanel]

    check(!hub.keepsPalettesInFront, "palettes are not pinned in front by default")
    check(panels.allSatisfy { $0.level == .normal },
          "so they sit in the normal window order")
    check(panels.allSatisfy { !$0.isFloatingPanel },
          "and do not behave as floating panels")

    hub.keepsPalettesInFront = true
    check(panels.allSatisfy { $0.level == .floating }, "turning the setting on pins them")
    check(panels.allSatisfy { $0.isFloatingPanel }, "as floating panels")

    hub.keepsPalettesInFront = false
    check(panels.allSatisfy { $0.level == .normal }, "and turning it off releases them")

    // Palettes still survive the app losing focus either way.
    check(panels.allSatisfy { !$0.hidesOnDeactivate },
          "they do not vanish when another app is used")
}

windowSection("palettes follow the active tab") {
    let hub = PaletteHub()
    let first = MainWindowController(doc: Document(width: 100, height: 80), hub: hub)
    check(hub.activeController === first, "the first tab owns the palettes")

    if let layers = hub.dock.palette(id: "layers") {
        hub.dock.dock(layers, to: .right)
        check(first.rightRail.boxes.count == 1, "docked into the first tab's rail")

        let second = MainWindowController(doc: Document(width: 60, height: 40), hub: hub)
        check(hub.activeController === second, "creating a tab moves the palettes to it")
        check(first.rightRail.isEmpty, "the old tab's rail is empty again")
        equal(second.rightRail.boxes.count, 1, "the new tab's rail holds the palette")
        equal(layers.side, .right, "the palette stayed docked through the move")

        // Palette callbacks must act on the newly active document.
        hub.layersPanel.onAdd?()
        equal(second.doc.layers.count, 2, "the Layers palette edits the active tab")
        equal(first.doc.layers.count, 1, "the background tab is untouched")

        // Switching back returns the palettes.
        hub.attach(to: first)
        check(second.rightRail.isEmpty, "rails follow the active tab both ways")
        equal(first.rightRail.boxes.count, 1, "palette came back to the first tab")

        // Rail width survives the hand-off.
        first.rightRail.width = 210
        hub.attach(to: second)
        near(second.rightRail.width, 210, 0.5, "rail width carries across tabs")
    } else {
        check(false, "the hub registered a Layers palette")
    }

    // One shared set of panels, not one per tab.
    equal(hub.toolsPanel, first.toolsPanel, "tabs share the Tools palette")
    equal(hub.colorsPanel, first.colorsPanel, "tabs share the Colors palette")
}

section("size sheet keeps proportions")
do {
    let widthField = NSTextField(string: "800")
    let heightField = NSTextField(string: "600")
    let ratio = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    ratio.state = .on
    let linker = AspectLinker(width: widthField, height: heightField, ratio: ratio, aspect: 800.0 / 600.0)

    widthField.integerValue = 400
    linker.widthChanged()
    equal(heightField.integerValue, 300, "height follows width")

    heightField.integerValue = 150
    linker.heightChanged()
    equal(widthField.integerValue, 200, "width follows height")

    ratio.state = .off
    widthField.integerValue = 1000
    linker.widthChanged()
    equal(heightField.integerValue, 150, "unlinked fields stay put")
}

section("documents from before the rename still open")
do {
    let doc = Document(width: 12, height: 9)
    doc.selectedLayer?.fill(with: .green)
    let legacy = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sketchy-legacy-\(UUID().uuidString).ptd")
    do {
        try doc.write(to: legacy)
        check(Document.isNative(legacy), ".ptd still counts as a layered document")

        // Rewrite the format marker the way the old build wrote it.
        var plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: legacy), options: [], format: nil) as? [String: Any] ?? [:]
        plist["format"] = "Painted Document"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: legacy)

        let reopened = try Document.open(url: legacy)
        equal(reopened.width, 12, "an old file opens by its old marker")
        equal(pixel(reopened, 6, 4)?.g ?? 0, 255, "with its pixels intact")
    } catch {
        check(false, "legacy round trip threw \(error)")
    }
    try? FileManager.default.removeItem(at: legacy)
}

// MARK: - Floating pixels

section("an oversized paste survives being moved")
do {
    // Canvas is 20x20; the pasted image is 40x40 with a red mark in one corner.
    let doc = Document(width: 20, height: 20)
    let clip = Layer(width: 40, height: 40, name: "clip")
    clip.fill(with: .blue)
    clip.context.setFillColor(NSColor.red.cgColor)
    clip.context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))   // bottom-left of the clip

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: -10, y: -10))

    check(engine.hasFloatingPixels, "the paste is floating, not drawn")
    equal(doc.history.entries.count, 1, "nothing is committed yet")
    // The layer itself is untouched until the pixels are dropped, but the
    // canvas shows them where they will land.
    equal(PixelOps.sample(doc.selectedLayer!, x: 10, y: 10)?.r ?? 0, 255,
          "the layer is untouched while floating")
    check((pixel(doc, 10, 10)?.b ?? 0) > 200, "while the canvas shows the floating paste")

    // Drag it far off the canvas, then back: the pixels are still all there.
    engine.mouseDown(at: CGPoint(x: 5, y: 5), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 200, y: 200), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 200, y: 200), modifiers: [])
    check(engine.hasFloatingPixels, "still floating after a drag off canvas")

    engine.mouseDown(at: CGPoint(x: 200, y: 200), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 15, y: 15), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 15, y: 15), modifiers: [])
    // The first drag pushed it +195, the second pulled it back -185.
    near(engine.floatingRect.minX, 0, 0.5, "a second drag continues from where it stopped")

    // Nudge the red corner into view, then drop it.
    engine.nudgeFloatingPixels(dx: 10, dy: 10)
    near(engine.floatingRect.minX, 10, 0.5, "nudging moves it further")
    check(engine.commitFloatingPixels(), "the drop lands")
    check(!engine.hasFloatingPixels, "nothing is floating afterwards")
    equal(doc.history.currentTitle, "Paste", "one history step for the paste")

    // The clip landed at (10, 10), so its red corner covers 10...18.
    let corner = pixel(doc, 14, 14)
    equal(corner?.r ?? 0, 255, "the red corner made it onto the canvas")
    check(Int(corner?.b ?? 255) < 60, "and it is red, not the blue field")
}

section("pasted pixels are not resampled")
do {
    // Two hard-edged halves: any smoothing shows up as a blended column.
    let doc = Document(width: 40, height: 40)
    let clip = Layer(width: 8, height: 8, name: "clip")
    clip.context.setFillColor(NSColor.red.cgColor)
    clip.context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
    clip.context.setFillColor(NSColor.blue.cgColor)
    clip.context.fill(CGRect(x: 4, y: 0, width: 4, height: 8))

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 10, y: 10))

    // Drag with a fractional delta, the way a real pointer moves.
    engine.mouseDown(at: CGPoint(x: 14, y: 14), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 22.4, y: 22.6), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 22.4, y: 22.6), modifiers: [])
    let frame = engine.floatingRect
    equal(frame.origin.x.truncatingRemainder(dividingBy: 1), 0, "the frame snaps to whole pixels")
    equal(frame.origin.y.truncatingRemainder(dividingBy: 1), 0, "vertically too")
    engine.commitFloatingPixels()

    let left = pixel(doc, Int(frame.minX) + 1, Int(frame.minY) + 4)
    let right = pixel(doc, Int(frame.minX) + 6, Int(frame.minY) + 4)
    equal(left?.r ?? 0, 255, "the red half stayed pure red")
    equal(left?.b ?? 255, 0, "with no blue bleeding in")
    equal(right?.b ?? 0, 255, "the blue half stayed pure blue")
    equal(right?.r ?? 255, 0, "with no red bleeding in")
}

section("resizing floating pixels")
do {
    let doc = Document(width: 60, height: 60)
    let clip = Layer(width: 10, height: 10, name: "clip")
    clip.fill(with: .red)

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 10, y: 10))

    // Grabbing a corner scales the pixels instead of moving them.
    let corner = engine.floatingHandles()[4]
    equal(corner, CGPoint(x: 20, y: 20), "the corner handle sits on the frame")
    engine.mouseDown(at: corner, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 50, y: 40), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 50, y: 40), modifiers: [])
    equal(engine.floatingRect, CGRect(x: 10, y: 10, width: 40, height: 30), "the frame follows the handle")

    engine.commitFloatingPixels()
    equal(pixel(doc, 45, 35)?.r ?? 0, 255, "pixels cover the enlarged area")
    check(Int(pixel(doc, 45, 35)?.g ?? 255) < 60, "and kept their colour")
    check(Int(pixel(doc, 55, 35)?.g ?? 0) > 200, "beyond the frame is untouched")

    // Shift keeps the proportions.
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 0, y: 0))
    engine.mouseDown(at: engine.floatingHandles()[4], rightButton: false, modifiers: [.shift])
    engine.mouseDragged(to: CGPoint(x: 40, y: 15), modifiers: [.shift])
    engine.mouseUp(at: CGPoint(x: 40, y: 15), modifiers: [.shift])
    equal(engine.floatingRect.width, engine.floatingRect.height, "shift keeps it square")
    engine.cancelFloatingPixels()
}

section("small floating blocks still move")
do {
    // Regression: handles used to cover the whole interior of a small block.
    let doc = Document(width: 60, height: 60)
    let clip = Layer(width: 10, height: 10, name: "clip")
    clip.fill(with: .red)

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 10, y: 10))

    engine.mouseDown(at: CGPoint(x: 15, y: 15), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 35, y: 35), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 35, y: 35), modifiers: [])
    equal(engine.floatingRect.size, CGSize(width: 10, height: 10), "a drag from the middle does not resize")
    equal(engine.floatingRect.origin, CGPoint(x: 30, y: 30), "it moves instead")
    engine.cancelFloatingPixels()
}

section("floating pixels can be put back")
do {
    let doc = Document(width: 30, height: 30, background: nil)
    doc.selectedLayer?.context.setFillColor(NSColor.red.cgColor)
    doc.selectedLayer?.context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)

    // Lifting empties the source, dragging moves the floating copy.
    engine.mouseDown(at: CGPoint(x: 5, y: 5), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 25, y: 25), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 25, y: 25), modifiers: [])
    check(Int(pixel(doc, 5, 5)?.a ?? 255) < 60, "the pixels left their old spot")

    // Escape puts them back exactly where they were.
    engine.cancelFloatingPixels()
    check(!engine.hasFloatingPixels, "the float is gone")
    equal(pixel(doc, 5, 5)?.r ?? 0, 255, "the lifted pixels are restored")
    equal(doc.history.entries.count, 1, "a cancelled move leaves no history")

    // Committing a real move writes to the new spot only.
    engine.mouseDown(at: CGPoint(x: 5, y: 5), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 25, y: 25), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 25, y: 25), modifiers: [])
    engine.commitFloatingPixels()
    equal(pixel(doc, 25, 25)?.r ?? 0, 255, "the pixels landed at the new spot")
    check(Int(pixel(doc, 5, 5)?.a ?? 255) < 60, "and left the old one empty")
    equal(doc.history.currentTitle, "Move Selected Pixels", "one history step for the move")
}

section("mask outlines are boundary loops")
do {
    // A solid block should come out as one four-corner loop, not a stack of
    // one-row rectangles that stroke every internal edge.
    var mask = [Bool](repeating: false, count: 20 * 20)
    for y in 5..<15 { for x in 4..<12 { mask[y * 20 + x] = true } }
    let block = PixelOps.path(from: mask, width: 20, height: 20)

    var elements = 0
    block.applyWithBlock { _ in elements += 1 }
    // move, three lines, and a close that draws the fourth side.
    equal(elements, 5, "a rectangle traces as four corners")
    equal(block.boundingBoxOfPath, CGRect(x: 4, y: 5, width: 8, height: 10), "covering the block")
    check(block.contains(CGPoint(x: 8, y: 10), using: .evenOdd), "the inside fills")
    check(!block.contains(CGPoint(x: 2, y: 10), using: .evenOdd), "the outside does not")

    // A ring: the hole has to come out as its own loop so it stays unselected.
    var ring = [Bool](repeating: false, count: 20 * 20)
    for y in 4..<16 { for x in 4..<16 { ring[y * 20 + x] = true } }
    for y in 8..<12 { for x in 8..<12 { ring[y * 20 + x] = false } }
    let ringPath = PixelOps.path(from: ring, width: 20, height: 20)
    check(ringPath.contains(CGPoint(x: 5, y: 10), using: .evenOdd), "the ring itself is inside")
    check(!ringPath.contains(CGPoint(x: 10, y: 10), using: .evenOdd), "the hole is not")

    // Two separate blobs stay separate.
    var pair = [Bool](repeating: false, count: 20 * 20)
    for y in 2..<5 { for x in 2..<5 { pair[y * 20 + x] = true } }
    for y in 14..<18 { for x in 14..<18 { pair[y * 20 + x] = true } }
    let pairPath = PixelOps.path(from: pair, width: 20, height: 20)
    check(pairPath.contains(CGPoint(x: 3, y: 3), using: .evenOdd), "the first blob is inside")
    check(pairPath.contains(CGPoint(x: 16, y: 16), using: .evenOdd), "so is the second")
    check(!pairPath.contains(CGPoint(x: 10, y: 10), using: .evenOdd), "the gap between them is not")
}

section("brush tip tools")
do {
    check(ToolID.paintbrush.hasBrushTip, "the paintbrush shows its radius")
    check(ToolID.eraser.hasBrushTip, "so does the eraser")
    check(ToolID.cloneStamp.hasBrushTip, "and the clone stamp")
    check(ToolID.recolor.hasBrushTip, "and recolor")
    check(!ToolID.pencil.hasBrushTip, "the pencil is one pixel, so no ring")
    check(!ToolID.rectangleSelect.hasBrushTip, "and the selection tools have none")
    check(!ToolID.paintBucket.hasBrushTip, "nor the bucket")
}

section("tolerance is per channel")
do {
    // Two colors that differ by 60 on one channel only. At 10% (25 per
    // channel) the fill must stop at the boundary; summing the channels used
    // to let far bigger differences through.
    let doc = Document(width: 8, height: 4, background: nil)
    let l = doc.selectedLayer!
    l.context.setFillColor(NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1).cgColor)
    l.context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    l.context.setFillColor(NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4 + 60.0 / 255, alpha: 1).cgColor)
    l.context.fill(CGRect(x: 4, y: 0, width: 4, height: 4))

    func spread(_ tolerance: CGFloat) -> Int {
        guard let mask = PixelOps.mask(in: l, seedX: 1, seedY: 1,
                                       tolerance: tolerance, contiguous: true) else { return 0 }
        return mask.filter { $0 }.count
    }

    equal(spread(0.1), 16, "10% keeps the fill inside the color it started on")
    equal(spread(0.5), 16, "so does half way up the slider")
    equal(spread(0.7), 32, "70% reaches across a 60/255 step")
    equal(spread(1.0), 32, "and the top of the slider takes everything")

    // Three channels each off by 40: still one step of 40, not a sum of 120.
    let mixed = Document(width: 4, height: 2, background: nil)
    let m = mixed.selectedLayer!
    m.context.setFillColor(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).cgColor)
    m.context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let off = CGFloat(40) / 255
    m.context.setFillColor(NSColor(srgbRed: 0.5 + off, green: 0.5 + off, blue: 0.5 + off, alpha: 1).cgColor)
    m.context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
    let wide = PixelOps.mask(in: m, seedX: 0, seedY: 0, tolerance: 0.6, contiguous: true)?
        .filter { $0 }.count ?? 0
    equal(wide, 8, "60% covers a 40-per-channel step on every channel at once")
    let narrow = PixelOps.mask(in: m, seedX: 0, seedY: 0, tolerance: 0.4, contiguous: true)?
        .filter { $0 }.count ?? 0
    equal(narrow, 4, "40% still treats it as a different color")

    // The curve is what keeps the middle of the slider usable.
    equal(PixelOps.channelLimit(for: 0), 0, "zero tolerance matches only the exact color")
    equal(PixelOps.channelLimit(for: 1), 255, "the top matches anything")
    check(PixelOps.channelLimit(for: 0.5) < 64, "half way up stays selective")
    check(PixelOps.channelLimit(for: 0.7) < 128, "70% is still short of half the range")
}

section("wand and bucket land on the right rows")
do {
    // Asymmetric on purpose: a band across the top only. A vertical flip in the
    // mask maths would put the result at the bottom and go unnoticed on a
    // symmetric shape.
    let doc = Document(width: 60, height: 40)
    let layer = doc.selectedLayer!
    layer.context.setFillColor(NSColor.black.cgColor)
    layer.context.fill(CGRect(x: 0, y: 30, width: 60, height: 10))   // top band

    let settings = ToolSettings()
    settings.tool = .magicWand
    settings.tolerance = 0.05
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.mouseDown(at: CGPoint(x: 30, y: 35), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 30, y: 35), modifiers: [])

    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, CGRect(x: 0, y: 30, width: 60, height: 10),
          "the wand selects the band it was clicked on")
    check(doc.selectionPath?.contains(CGPoint(x: 30, y: 35)) ?? false, "the clicked pixel is inside")
    check(!(doc.selectionPath?.contains(CGPoint(x: 30, y: 5)) ?? true), "the opposite band is not")

    // An off-centre corner, to catch a horizontal slip too.
    let corner = Document(width: 60, height: 40)
    corner.selectedLayer?.context.setFillColor(NSColor.blue.cgColor)
    corner.selectedLayer?.context.fill(CGRect(x: 40, y: 0, width: 20, height: 12))
    let cornerEngine = ToolEngine(doc: corner, settings: settings)
    cornerEngine.mouseDown(at: CGPoint(x: 50, y: 6), rightButton: false, modifiers: [])
    cornerEngine.mouseUp(at: CGPoint(x: 50, y: 6), modifiers: [])
    equal(corner.selectionPath?.boundingBoxOfPath ?? .zero, CGRect(x: 40, y: 0, width: 20, height: 12),
          "the wand finds a bottom-right block where it actually is")

    // The bucket shares the same mask maths.
    let bucketDoc = Document(width: 60, height: 40)
    bucketDoc.selectedLayer?.context.setFillColor(NSColor.black.cgColor)
    bucketDoc.selectedLayer?.context.fill(CGRect(x: 0, y: 30, width: 60, height: 10))
    let bucketSettings = ToolSettings()
    bucketSettings.tool = .paintBucket
    bucketSettings.tolerance = 0.05
    let bucket = ToolEngine(doc: bucketDoc, settings: bucketSettings)
    bucket.primaryColor = .red
    bucket.mouseDown(at: CGPoint(x: 30, y: 35), rightButton: false, modifiers: [])
    bucket.mouseUp(at: CGPoint(x: 30, y: 35), modifiers: [])

    equal(pixel(bucketDoc, 30, 35)?.r ?? 0, 255, "the bucket filled the band that was clicked")
    check(Int(pixel(bucketDoc, 30, 35)?.b ?? 255) < 60, "and it is red")
    equal(pixel(bucketDoc, 30, 5)?.r ?? 0, 255, "the untouched area is still white")
    equal(pixel(bucketDoc, 30, 5)?.b ?? 0, 255, "and still has its blue channel")
}

section("scaling keeps pixels hard-edged")
do {
    // A 2x2 checker blown up 8x: nearest neighbour keeps four solid blocks,
    // smoothing turns the middle into a gradient.
    func checker() -> Document {
        let doc = Document(width: 2, height: 2, background: nil)
        let layer = doc.selectedLayer!
        layer.context.setFillColor(NSColor.black.cgColor)
        layer.context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        layer.context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        layer.context.setFillColor(NSColor.white.cgColor)
        layer.context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        layer.context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        return doc
    }

    let hard = checker()
    hard.resizeImage(to: CGSize(width: 16, height: 16), resampling: .pixels)
    let blackBlock = pixel(hard, 3, 3)
    let whiteBlock = pixel(hard, 12, 3)
    equal(blackBlock?.r ?? 255, 0, "the black quarter stayed black")
    equal(whiteBlock?.r ?? 0, 255, "the white quarter stayed white")
    // The boundary must be a hard step, not a ramp.
    let left = pixel(hard, 7, 3)?.r ?? 0
    let right = pixel(hard, 8, 3)?.r ?? 0
    check(abs(Int(left) - Int(right)) > 200, "the edge between them is a hard step")

    let soft = checker()
    soft.resizeImage(to: CGSize(width: 16, height: 16), resampling: .smooth)
    let softLeft = soft.selectedLayer.flatMap { PixelOps.sample($0, x: 7, y: 3)?.r } ?? 0
    let softRight = soft.selectedLayer.flatMap { PixelOps.sample($0, x: 8, y: 3)?.r } ?? 0
    check(abs(Int(softLeft) - Int(softRight)) < 200, "smoothing blends the same edge")

    equal(ToolSettings().resampling, .pixels, "pixel art is the default")
}

section("resizing past an edge flips the pixels")
do {
    // Left half red, right half blue: a horizontal flip swaps them.
    let doc = Document(width: 60, height: 40)
    let clip = Layer(width: 20, height: 10, name: "clip")
    clip.context.setFillColor(NSColor.red.cgColor)
    clip.context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    clip.context.setFillColor(NSColor.blue.cgColor)
    clip.context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 20, y: 20))

    // Grab the right edge and drag it well past the left edge.
    let rightEdge = engine.floatingHandles()[3]
    equal(rightEdge, CGPoint(x: 40, y: 25), "the right-edge handle is where it should be")
    engine.mouseDown(at: rightEdge, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 0, y: 25), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 0, y: 25), modifiers: [])

    let frame = engine.floatingRect
    check(engine.floatingIsMirrored.x, "the drag past the edge mirrored horizontally")
    check(!engine.floatingIsMirrored.y, "and left the vertical alone")
    check(frame.width > 0 && frame.height > 0, "the frame stays a real rectangle")
    near(frame.maxX, 20, 1, "it now sits to the left of the anchor")
    engine.commitFloatingPixels()

    // Red started on the left; after mirroring it is on the right.
    let leftSample = pixel(doc, Int(frame.minX) + 2, 25)
    let rightSample = pixel(doc, Int(frame.maxX) - 2, 25)
    equal(leftSample?.b ?? 0, 255, "blue is on the left after the flip")
    equal(rightSample?.r ?? 0, 255, "red is on the right after the flip")
}

section("resizing without crossing does not mirror")
do {
    let doc = Document(width: 60, height: 40)
    let clip = Layer(width: 20, height: 10, name: "clip")
    clip.context.setFillColor(NSColor.red.cgColor)
    clip.context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    clip.context.setFillColor(NSColor.blue.cgColor)
    clip.context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 20, y: 20))

    // Shrink from the right without passing the left edge.
    engine.mouseDown(at: engine.floatingHandles()[3], rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 30, y: 25), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 30, y: 25), modifiers: [])
    check(!engine.floatingIsMirrored.x, "shrinking does not mirror")
    equal(engine.floatingRect, CGRect(x: 20, y: 20, width: 10, height: 10), "the anchor edge held")

    // Vertical: drag the top handle below the bottom edge.
    engine.mouseDown(at: engine.floatingHandles()[5], rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 25, y: 5), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 25, y: 5), modifiers: [])
    check(engine.floatingIsMirrored.y, "dragging the top past the bottom mirrors vertically")
    check(!engine.floatingIsMirrored.x, "and leaves the horizontal alone")
    engine.cancelFloatingPixels()
}

section("scaled floating pixels stay hard-edged")
do {
    // Two-pixel wide clip blown up: with Pixels scaling the seam stays a step.
    let doc = Document(width: 40, height: 40, background: nil)
    let clip = Layer(width: 2, height: 1, name: "clip")
    clip.context.setFillColor(NSColor.black.cgColor)
    clip.context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    clip.context.setFillColor(NSColor.white.cgColor)
    clip.context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    settings.resampling = .pixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 0, y: 0))
    engine.mouseDown(at: engine.floatingHandles()[4], rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 40, y: 20), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 40, y: 20), modifiers: [])
    engine.commitFloatingPixels()

    let left = pixel(doc, 19, 10)?.r ?? 0
    let right = pixel(doc, 21, 10)?.r ?? 0
    check(abs(Int(left) - Int(right)) > 200, "the seam is a hard step, not a gradient")
}

section("selection size is reported while dragging")
do {
    let doc = Document(width: 100, height: 100)
    let settings = ToolSettings()
    settings.tool = .rectangleSelect
    let engine = ToolEngine(doc: doc, settings: settings)

    check(engine.measuredRect == nil, "nothing to measure before a selection exists")

    // Mid-drag the marquee reports its live size, not the old selection's.
    engine.mouseDown(at: CGPoint(x: 10, y: 20), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 45, y: 70), modifiers: [])
    equal(engine.measuredRect?.width ?? 0, 35, "width updates during the drag")
    equal(engine.measuredRect?.height ?? 0, 50, "height updates during the drag")

    engine.mouseUp(at: CGPoint(x: 45, y: 70), modifiers: [])
    equal(engine.measuredRect ?? .zero, CGRect(x: 10, y: 20, width: 35, height: 50),
          "the committed selection keeps reporting its size")

    // An ellipse reports the box it fills.
    settings.tool = .ellipseSelect
    engine.mouseDown(at: CGPoint(x: 0, y: 0), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 20, y: 12), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 20, y: 12), modifiers: [])
    equal(engine.measuredRect?.width ?? 0, 20, "an ellipse measures its bounds")

    doc.deselect()
    check(engine.measuredRect == nil, "deselecting clears the readout")

    // Floating pixels report their own size, so a resize can be measured.
    settings.tool = .moveSelectedPixels
    let clip = Layer(width: 16, height: 9, name: "clip")
    clip.fill(with: .red)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 5, y: 5))
    equal(engine.measuredRect ?? .zero, CGRect(x: 5, y: 5, width: 16, height: 9),
          "pasted pixels report their size")
    engine.mouseDown(at: engine.floatingHandles()[4], rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 45, y: 35), modifiers: [])
    equal(engine.measuredRect?.width ?? 0, 40, "resizing updates the reported width")
    engine.cancelFloatingPixels()

    // A shape being placed measures too.
    settings.tool = .shapes
    settings.shape = .rectangle
    engine.mouseDown(at: CGPoint(x: 30, y: 30), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 60, y: 45), modifiers: [])
    near(engine.measuredRect?.width ?? 0, 30, 0.6, "a shape reports its width as it is drawn")
    near(engine.measuredRect?.height ?? 0, 15, 0.6, "and its height")
}

section("a paste is cemented straight into the layer")
do {
    // No tool has to be picked and nothing is asked: the pixels land, clipped
    // to the canvas, and what landed becomes the selection.
    let doc = Document(width: 20, height: 20)
    let clip = Layer(width: 40, height: 40, name: "clip")
    clip.fill(with: .red)

    let landed = doc.paste(clip.image!)
    equal(doc.history.currentTitle, "Paste", "one history step, already committed")
    equal(pixel(doc, 10, 10)?.r ?? 0, 255, "the pixels are in the layer, not floating")
    check(Int(pixel(doc, 10, 10)?.g ?? 255) < 60, "and they are the pasted red")
    equal(landed?.width ?? 0, 40, "the paste reports its own size")
    // A 40x40 clip lands at y = 20 - 40 = -20, so only its top-left quarter is
    // on the canvas and only that much may be selected.
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, doc.bounds,
          "the selection covers only what fitted")
}

section("paste scaled to the canvas")
do {
    // A wide clip on a square canvas: the two canvas scales differ visibly.
    let canvas = CGSize(width: 40, height: 40)
    let wide = CGSize(width: 20, height: 10)

    equal(Document.PasteScale.stretchToCanvas.destination(imageSize: wide, canvas: canvas,
                                                          corner: CGPoint(x: 7, y: 7)),
          CGRect(origin: .zero, size: canvas), "stretching fills the canvas and ignores the corner")
    // Fitting scales by the tighter axis — 40/20 = 2 — and centres the slack one.
    equal(Document.PasteScale.fitToCanvas.destination(imageSize: wide, canvas: canvas,
                                                      corner: CGPoint(x: 7, y: 7)),
          CGRect(x: 0, y: 10, width: 40, height: 20), "fitting keeps proportions and centres")
    equal(Document.PasteScale.actualSize.destination(imageSize: wide, canvas: canvas,
                                                     corner: CGPoint(x: 7, y: 7)),
          CGRect(x: 7, y: 7, width: 20, height: 10), "actual size lands on the corner given")

    // A taller-than-wide clip fits against the other axis instead.
    equal(Document.PasteScale.fitToCanvas.destination(imageSize: CGSize(width: 10, height: 20),
                                                      canvas: canvas, corner: .zero),
          CGRect(x: 10, y: 0, width: 20, height: 40), "the tighter axis decides which way it fits")
    // Nothing to scale: a degenerate image falls back to the whole canvas
    // rather than dividing by zero.
    equal(Document.PasteScale.fitToCanvas.destination(imageSize: .zero, canvas: canvas, corner: .zero),
          CGRect(origin: .zero, size: canvas), "an empty image cannot be fitted")
}

section("a stretched paste covers the canvas")
do {
    let doc = Document(width: 40, height: 40)
    let clip = Layer(width: 20, height: 10, name: "clip")
    clip.fill(with: .red)

    let landed = doc.paste(clip.image!, scale: .stretchToCanvas)
    equal(landed ?? .zero, doc.bounds, "the paste covers the whole canvas")
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, doc.bounds, "and so does the selection")
    for (x, y) in [(2, 2), (37, 37), (20, 2), (2, 37)] {
        equal(pixel(doc, x, y)?.r ?? 0, 255, "corner \(x),\(y) is painted")
        check(Int(pixel(doc, x, y)?.g ?? 255) < 60, "and it is the pasted red")
    }
}

section("a fitted paste keeps its proportions")
do {
    let doc = Document(width: 40, height: 40, background: .white)
    let clip = Layer(width: 20, height: 10, name: "clip")
    clip.fill(with: .red)

    let landed = doc.paste(clip.image!, scale: .fitToCanvas)
    equal(landed ?? .zero, CGRect(x: 0, y: 10, width: 40, height: 20), "scaled x2 and centred")
    equal(pixel(doc, 20, 20)?.r ?? 0, 255, "the middle is painted")
    check(Int(pixel(doc, 20, 20)?.g ?? 255) < 60, "with the pasted red")
    // The bands above and below are untouched: fitting does not distort.
    equal(pixel(doc, 20, 2)?.g ?? 0, 255, "the band below is left alone")
    equal(pixel(doc, 20, 37)?.g ?? 0, 255, "and the band above")
}

section("tool shortcuts")
do {
    let suite = "SketchySelfTest-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suite)!
    var shortcuts = ToolShortcuts(store: store)

    equal(shortcuts.key(for: .paintbrush), "b", "the shipped key for the brush")
    equal(shortcuts.key(for: .eraser), "e", "and for the eraser")

    // The three selection tools share one key and cycle in palette order.
    let sharing = shortcuts.tools(for: "s")
    equal(sharing, [.rectangleSelect, .lassoSelect, .ellipseSelect], "selection tools share S")
    equal(shortcuts.nextTool(for: "s", after: .rectangleSelect), .lassoSelect, "S walks to the next")
    equal(shortcuts.nextTool(for: "s", after: .ellipseSelect), .rectangleSelect, "and wraps around")
    equal(shortcuts.nextTool(for: "b", after: .eraser), .paintbrush, "a key not on the current tool jumps to it")
    check(shortcuts.nextTool(for: "9", after: .paintbrush) == nil, "an unassigned key does nothing")

    // Rebinding.
    shortcuts.setKey("Q", for: .paintbrush)
    equal(shortcuts.key(for: .paintbrush), "q", "keys are stored lowercase")
    equal(shortcuts.nextTool(for: "q", after: .eraser), .paintbrush, "the new key works")
    check(shortcuts.nextTool(for: "b", after: .eraser) == nil, "the old key no longer does")

    shortcuts.setKey("", for: .eraser)
    check(shortcuts.key(for: .eraser) == nil, "an empty key unassigns the tool")
    shortcuts.setKey("longer", for: .pencil)
    equal(shortcuts.key(for: .pencil), "l", "only the first character is kept")

    // Changes survive a restart.
    shortcuts = ToolShortcuts(store: store)
    equal(shortcuts.key(for: .paintbrush), "q", "rebinding is remembered")
    check(shortcuts.key(for: .eraser) == nil, "so is unassigning")

    shortcuts.reset()
    equal(shortcuts.key(for: .paintbrush), "b", "restoring defaults brings the shipped keys back")
    equal(shortcuts.key(for: .eraser), "e", "for every tool")

    store.removePersistentDomain(forName: suite)
}

section("canvas size limits")
do {
    let sixteenGB = 16_000_000_000

    // Ordinary sizes are waved through.
    equal(Document.verdict(width: 800, height: 600, physicalMemory: sixteenGB), .fine,
          "a normal canvas is fine")
    equal(Document.verdict(width: 4000, height: 3000, layers: 3, physicalMemory: sixteenGB), .fine,
          "so is a photo with a few layers")

    // 20000 x 20000 is 1.6 GB a layer, and the compositing buffer doubles it.
    equal(Document.bytesNeeded(width: 20000, height: 20000), 3_200_000_000,
          "one layer plus its composite is 3.2 GB")
    if case .heavy(let bytes) = Document.verdict(width: 20000, height: 20000, physicalMemory: sixteenGB) {
        equal(bytes, 3_200_000_000, "a 20k canvas warns rather than refuses on 16 GB")
    } else {
        check(false, "20k on 16 GB should warn")
    }

    // The same canvas on a smaller machine is refused outright.
    if case .tooLarge = Document.verdict(width: 20000, height: 20000, physicalMemory: 4_000_000_000) {
        check(true, "refused on a 4 GB machine")
    } else {
        check(false, "20k on 4 GB should be refused")
    }

    // Layers multiply it, so the check counts them.
    if case .tooLarge = Document.verdict(width: 20000, height: 20000, layers: 6,
                                         physicalMemory: sixteenGB) {
        check(true, "six layers at 20k is refused even on 16 GB")
    } else {
        check(false, "layer count should count against the limit")
    }

    // 15000 a side is where a warning starts, whatever the machine has.
    let plentyOfMemory = 512_000_000_000
    equal(Document.verdict(width: 15000, height: 15000, physicalMemory: plentyOfMemory), .fine,
          "15k a side is still waved through")
    if case .heavy = Document.verdict(width: 15001, height: 800, physicalMemory: plentyOfMemory) {
        check(true, "a pixel past it warns even on a machine with memory to spare")
    } else {
        check(false, "past 15000 a side should warn")
    }
    if case .heavy = Document.verdict(width: 50000, height: 50000, physicalMemory: plentyOfMemory) {
        check(true, "50k a side is allowed on a machine that can hold it")
    } else {
        check(false, "50k should be the hard limit, not below it")
    }
    if case .tooLarge = Document.verdict(width: 50001, height: 10, physicalMemory: plentyOfMemory) {
        check(true, "a pixel past the hard limit is refused")
    } else {
        check(false, "50001 should be refused")
    }
    // Memory still has the last word: a 50k canvas is 10 GB a layer.
    if case .tooLarge = Document.verdict(width: 50000, height: 50000, physicalMemory: sixteenGB) {
        check(true, "and refused outright when the machine cannot hold it")
    } else {
        check(false, "50k on 16 GB should be refused")
    }

    // Absurd dimensions are rejected before any arithmetic about memory.
    if case .tooLarge(let reason) = Document.verdict(width: 100_000, height: 10,
                                                     physicalMemory: sixteenGB) {
        check(reason.contains("50000"), "a side beyond the hard limit is named as the reason")
    } else {
        check(false, "100k wide should be refused")
    }
    if case .tooLarge = Document.verdict(width: 0, height: 100, physicalMemory: sixteenGB) {
        check(true, "zero width is refused")
    } else {
        check(false, "zero width should be refused")
    }
}

section("compositing only what is on screen")
do {
    let doc = Document(width: 2000, height: 1500, background: nil)
    let layer = doc.selectedLayer!
    layer.context.setFillColor(NSColor.red.cgColor)
    layer.context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))       // bottom left
    layer.context.setFillColor(NSColor.blue.cgColor)
    layer.context.fill(CGRect(x: 1800, y: 1300, width: 200, height: 200)) // top right

    // A slice comes back at the pixel size asked for, not the canvas size.
    let slice = doc.composite(region: CGRect(x: 0, y: 0, width: 400, height: 300),
                              pixelSize: CGSize(width: 400, height: 300))
    equal(slice?.width ?? 0, 400, "the buffer is the size requested")
    equal(slice?.height ?? 0, 300, "in both axes")

    let probe = Layer(width: slice!.width, height: slice!.height, name: "probe")
    probe.draw(image: slice!)
    equal(PixelOps.sample(probe, x: 50, y: 50)?.r ?? 0, 255, "the red corner is in this slice")
    check(Int(PixelOps.sample(probe, x: 50, y: 50)?.b ?? 255) < 60, "and it is red")
    check(Int(PixelOps.sample(probe, x: 380, y: 280)?.a ?? 255) < 60, "the rest of the slice is empty")

    // Zoomed out, the buffer is smaller than the region it covers.
    let thumb = doc.composite(region: doc.bounds, pixelSize: CGSize(width: 200, height: 150))
    equal(thumb?.width ?? 0, 200, "a zoomed-out view costs 200 pixels across")
    let thumbProbe = Layer(width: thumb!.width, height: thumb!.height, name: "thumb")
    thumbProbe.draw(image: thumb!)
    equal(PixelOps.sample(thumbProbe, x: 5, y: 5)?.r ?? 0, 255, "red still bottom left")
    equal(PixelOps.sample(thumbProbe, x: 195, y: 145)?.b ?? 0, 255, "blue still top right")

    check(doc.composite(region: CGRect(x: 5000, y: 5000, width: 10, height: 10),
                        pixelSize: CGSize(width: 10, height: 10)) == nil,
          "a region off the canvas composites to nothing")
}

section("history stays inside a memory budget")
do {
    let doc = Document(width: 1000, height: 1000)
    // A budget of three snapshots' worth: 1000 x 1000 x 4 = 4 MB each.
    doc.history.byteBudget = 12_000_000

    for step in 1...10 {
        doc.selectedLayer?.context.setFillColor(NSColor.black.cgColor)
        doc.selectedLayer?.context.fill(CGRect(x: step * 10, y: 0, width: 8, height: 1000))
        doc.commit("stroke \(step)")
    }

    check(doc.history.entries.count < 10, "old steps are dropped once the budget is passed")
    check(doc.history.estimatedBytes <= 12_000_000, "the kept steps fit the budget")
    check(doc.history.canUndo, "there is still something to undo")
    check(doc.undo(), "and undo still works")

    // A small document keeps its full history.
    let small = Document(width: 100, height: 100)
    for step in 1...10 { small.addLayer(named: "layer \(step)") }
    equal(small.history.entries.count, 11, "a small document keeps every step")
}

// MARK: - Combining selections

section("modifiers combine selections")
do {
    let doc = Document(width: 100, height: 100)
    let settings = ToolSettings()
    settings.tool = .rectangleSelect
    let engine = ToolEngine(doc: doc, settings: settings)

    func dragSelect(_ from: CGPoint, _ to: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) {
        engine.mouseDown(at: from, rightButton: false, modifiers: modifiers)
        engine.mouseDragged(to: to, modifiers: modifiers)
        engine.mouseUp(at: to, modifiers: modifiers)
    }
    func selected(_ x: CGFloat, _ y: CGFloat) -> Bool {
        doc.selectionPath?.contains(CGPoint(x: x, y: y)) ?? false
    }

    // A plain drag replaces whatever was selected.
    dragSelect(CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30))
    dragSelect(CGPoint(x: 60, y: 60), CGPoint(x: 80, y: 80))
    check(!selected(20, 20), "a second plain drag drops the first region")
    check(selected(70, 70), "the newest region is selected")

    // Option adds a second region without losing the first.
    dragSelect(CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30))
    dragSelect(CGPoint(x: 60, y: 60), CGPoint(x: 80, y: 80), [.option])
    check(selected(20, 20), "the first region survives")
    check(selected(70, 70), "the second region is added")
    check(!selected(45, 45), "the gap between them is not selected")

    // A third region joins the other two.
    dragSelect(CGPoint(x: 10, y: 60), CGPoint(x: 30, y: 80), [.option])
    check(selected(20, 20) && selected(70, 70) && selected(20, 70), "three regions at once")

    // Command subtracts.
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    dragSelect(CGPoint(x: 40, y: 40), CGPoint(x: 60, y: 60), [.command])
    check(selected(10, 10), "the untouched part stays")
    check(!selected(50, 50), "the dragged part is removed")

    // Option and command together intersect.
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil)
    dragSelect(CGPoint(x: 25, y: 25), CGPoint(x: 100, y: 100), [.option, .command])
    check(selected(35, 35), "the overlap stays")
    check(!selected(10, 10), "the rest of the old selection goes")
    check(!selected(70, 70), "the rest of the new region goes")

    // The magic wand honours the same modifiers.
    let wandDoc = Document(width: 40, height: 20)
    wandDoc.selectedLayer?.context.setFillColor(NSColor.black.cgColor)
    wandDoc.selectedLayer?.context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
    wandDoc.selectedLayer?.context.setFillColor(NSColor.blue.cgColor)
    wandDoc.selectedLayer?.context.fill(CGRect(x: 30, y: 0, width: 10, height: 20))
    let wandSettings = ToolSettings()
    wandSettings.tool = .magicWand
    wandSettings.tolerance = 0.05
    let wand = ToolEngine(doc: wandDoc, settings: wandSettings)

    wand.mouseDown(at: CGPoint(x: 5, y: 10), rightButton: false, modifiers: [])
    wand.mouseUp(at: CGPoint(x: 5, y: 10), modifiers: [])
    wand.mouseDown(at: CGPoint(x: 35, y: 10), rightButton: false, modifiers: [.option])
    wand.mouseUp(at: CGPoint(x: 35, y: 10), modifiers: [.option])
    let box = wandDoc.selectionPath?.boundingBoxOfPath ?? .zero
    near(box.minX, 0, 1, "the wand kept the black region")
    near(box.maxX, 40, 1, "and added the blue one")
    check(!(wandDoc.selectionPath?.contains(CGPoint(x: 20, y: 10)) ?? true),
          "the white gap between them stays unselected")
}

section("an inverted selection combines like any other")
do {
    let doc = Document(width: 100, height: 100)
    let settings = ToolSettings()
    settings.tool = .rectangleSelect
    let engine = ToolEngine(doc: doc, settings: settings)
    func dragSelect(_ from: CGPoint, _ to: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) {
        engine.mouseDown(at: from, rightButton: false, modifiers: modifiers)
        engine.mouseDragged(to: to, modifiers: modifiers)
        engine.mouseUp(at: to, modifiers: modifiers)
    }
    func selected(_ x: CGFloat, _ y: CGFloat) -> Bool {
        doc.selectionPath?.contains(CGPoint(x: x, y: y)) ?? false
    }

    dragSelect(CGPoint(x: 25, y: 25), CGPoint(x: 75, y: 75))
    doc.invertSelection()
    check(!selected(50, 50), "the inverted hole is not selected")
    check(selected(10, 10), "the ring around it is")
    check(doc.selectionPath?.contains(CGPoint(x: 50, y: 50), using: .evenOdd) == false,
          "and every fill rule agrees on it")

    // Adding somewhere else used to fill the hole back in.
    dragSelect(CGPoint(x: 0, y: 90), CGPoint(x: 5, y: 95), [.option])
    check(!selected(50, 50), "adding elsewhere leaves the hole alone")

    // Painting honours the hole too.
    doc.selectedLayer?.fill(with: .white)
    doc.selectedLayer.map { layer in
        layer.context.saveGState()
        doc.clipToSelection(layer.context)
        layer.context.setFillColor(NSColor.black.cgColor)
        layer.context.fill(doc.bounds)
        layer.context.restoreGState()
    }
    equal(pixel(doc, 50, 50)?.g ?? 0, 255, "the hole is not painted")
    check(Int(pixel(doc, 10, 10)?.g ?? 255) < 10, "the ring is")

    // A selection is kept to the canvas, and taking it all away deselects.
    dragSelect(CGPoint(x: 80, y: 80), CGPoint(x: 140, y: 140))
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, CGRect(x: 80, y: 80, width: 20, height: 20),
          "a marquee past the edge stops at the canvas")
    dragSelect(CGPoint(x: 70, y: 70), CGPoint(x: 100, y: 100), [.command])
    check(doc.selectionPath == nil, "subtracting everything leaves no selection, not an empty one")

    doc.selectAll()
    doc.invertSelection()
    check(doc.selectionPath == nil, "inverting everything leaves nothing selected")
}

section("clicking clears the selection")
do {
    let doc = Document(width: 50, height: 50)
    let settings = ToolSettings()
    settings.tool = .rectangleSelect
    let engine = ToolEngine(doc: doc, settings: settings)

    func click(_ at: CGPoint, _ modifiers: NSEvent.ModifierFlags = []) {
        engine.mouseDown(at: at, rightButton: false, modifiers: modifiers)
        engine.mouseUp(at: at, modifiers: modifiers)
    }

    doc.selectionPath = CGPath(rect: CGRect(x: 5, y: 5, width: 20, height: 20), transform: nil)
    click(CGPoint(x: 40, y: 40))
    check(doc.selectionPath == nil, "a click with no drag deselects")

    // The same for the other selection tools.
    doc.selectionPath = CGPath(rect: CGRect(x: 5, y: 5, width: 20, height: 20), transform: nil)
    settings.tool = .ellipseSelect
    click(CGPoint(x: 30, y: 30))
    check(doc.selectionPath == nil, "the ellipse tool deselects too")

    doc.selectionPath = CGPath(rect: CGRect(x: 5, y: 5, width: 20, height: 20), transform: nil)
    settings.tool = .lassoSelect
    click(CGPoint(x: 12, y: 34))
    check(doc.selectionPath == nil, "so does the lasso")

    // Holding a combining modifier means "keep what I have", so a stray click
    // must not throw the selection away.
    settings.tool = .rectangleSelect
    let kept = CGPath(rect: CGRect(x: 5, y: 5, width: 20, height: 20), transform: nil)
    doc.selectionPath = kept
    click(CGPoint(x: 40, y: 40), [.option])
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, kept.boundingBoxOfPath,
          "option-clicking leaves the selection alone")

    // A real drag still selects, however small.
    engine.mouseDown(at: CGPoint(x: 10, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 14, y: 13), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 14, y: 13), modifiers: [])
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, CGRect(x: 10, y: 10, width: 4, height: 3),
          "a small drag still selects")
}

section("a replacing drag drops the old selection at once")
do {
    let doc = Document(width: 50, height: 50)
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
    let settings = ToolSettings()
    settings.tool = .rectangleSelect
    let engine = ToolEngine(doc: doc, settings: settings)

    engine.mouseDown(at: CGPoint(x: 30, y: 30), rightButton: false, modifiers: [])
    check(doc.selectionPath == nil, "the old selection goes on mouse down, not on mouse up")
    engine.mouseDragged(to: CGPoint(x: 40, y: 40), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 40, y: 40), modifiers: [])
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, CGRect(x: 30, y: 30, width: 10, height: 10),
          "the new region replaces it")

    // Holding option keeps the old selection on screen while dragging.
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil)
    engine.mouseDown(at: CGPoint(x: 30, y: 30), rightButton: false, modifiers: [.option])
    check(doc.selectionPath != nil, "adding to a selection keeps it visible")
    engine.mouseUp(at: CGPoint(x: 30, y: 30), modifiers: [.option])
}

// MARK: - Resize anchors

section("canvas size anchor")
do {
    // A 10x10 red square that we grow to 30x30 from various anchors.
    func grown(from anchor: CGPoint) -> Document {
        let doc = Document(width: 10, height: 10, background: nil)
        doc.selectedLayer?.fill(with: .red)
        doc.resizeCanvas(to: CGSize(width: 30, height: 30), anchor: anchor)
        return doc
    }
    func opaque(_ doc: Document, _ x: Int, _ y: Int) -> Bool {
        (pixel(doc, x, y)?.a ?? 0) > 200
    }

    // Top-left cell: image keeps the top-left corner, space is added right and below.
    let topLeft = grown(from: CGPoint(x: 0, y: 1))
    check(opaque(topLeft, 5, 25), "top-left anchor keeps the image at the top-left")
    check(!opaque(topLeft, 25, 5), "the opposite corner is empty")

    let bottomRight = grown(from: CGPoint(x: 1, y: 0))
    check(opaque(bottomRight, 25, 5), "bottom-right anchor keeps the image at the bottom-right")
    check(!opaque(bottomRight, 5, 25), "the opposite corner is empty")

    let centered = grown(from: CGPoint(x: 0.5, y: 0.5))
    check(opaque(centered, 15, 15), "center anchor keeps the image in the middle")
    check(!opaque(centered, 2, 2), "corners are empty when centered")
    check(!opaque(centered, 28, 28), "far corner is empty when centered")

    equal(centered.width, 30, "canvas took the new width")
    equal(centered.history.currentTitle, "Canvas Size", "one history step")
}

section("document commands leave the layer clean")
do {
    // Building a layer through a transform or a quality setting must not leave
    // it behind: the layer outlives the command and every later edit inherits
    // whatever state was left on its context.
    func check(_ name: String, _ body: (Document) -> Void) {
        let doc = Document(width: 12, height: 8, background: nil)
        doc.selectedLayer?.fill(with: .red)
        body(doc)
        guard let ctx = doc.selectedLayer?.context else { return }
        equal(ctx.ctm, CGAffineTransform(scaleX: 1, y: 1), "\(name) leaves no transform behind")
        equal(ctx.interpolationQuality, .high, "\(name) leaves the default resampling")
    }

    check("rotate") { $0.rotate(turns: 1) }
    check("rotate 180") { $0.rotate(turns: 2) }
    check("crop") { $0.crop(to: CGRect(x: 1, y: 1, width: 6, height: 4)) }
    check("canvas size") { $0.resizeCanvas(to: CGSize(width: 20, height: 20)) }
    check("image size") {
        $0.resizeImage(to: CGSize(width: 24, height: 16), anchor: CGPoint(x: 0.5, y: 0.5),
                       fit: true, resampling: .pixels)
    }
    check("flip") { $0.flip(horizontal: true) }
    check("flip vertical") { $0.flip(horizontal: false) }
    check("rotate layer") { doc in
        if let l = doc.selectedLayer { doc.transformLayer(l, angle: 0.4, scale: 1.2, offset: .zero) }
    }
}

section("editing after a rotate")
do {
    // 20x10, red on the left, blue on the right. A clockwise turn puts red at
    // the top of a 10x20 canvas.
    let doc = Document(width: 20, height: 10, background: nil)
    let l = doc.selectedLayer!
    l.context.setFillColor(NSColor.red.cgColor)
    l.context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    l.context.setFillColor(NSColor.blue.cgColor)
    l.context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
    doc.commit("Fill")
    doc.rotate(turns: 3)

    equal(doc.width, 10, "the turn swaps the canvas width")
    equal(pixel(doc, 5, 17)?.r ?? 0, 255, "red lands at the top")
    equal(pixel(doc, 5, 2)?.b ?? 0, 255, "blue at the bottom")

    // Drawing has to land where it is asked for: a rotate that leaves its
    // transform on the layer sends every later edit somewhere else.
    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 12, width: 10, height: 8), transform: nil)
    engine.mouseDown(at: CGPoint(x: 5, y: 16), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 5, y: 6), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 5, y: 6), modifiers: [])
    engine.commitFloatingPixels()

    equal(pixel(doc, 5, 6)?.r ?? 0, 255, "moved pixels carry the rotated image")
    equal(pixel(doc, 5, 17)?.a ?? 255, 0, "and the place they came from is empty")
}

section("crop to selection")
do {
    let doc = Document(width: 20, height: 20, background: nil)
    doc.selectedLayer?.fill(with: .red)
    doc.commit("Fill")
    doc.selectionPath = CGPath(rect: CGRect(x: 4, y: 6, width: 8, height: 5), transform: nil)
    doc.crop(to: doc.selectionPath!.boundingBoxOfPath)

    equal(doc.width, 8, "crop takes the selection width")
    equal(doc.height, 5, "crop takes the selection height")
    check(doc.selectionPath == nil, "and drops the selection it cropped to")

    // The whole point: a crop is an edit, not a new document.
    equal(doc.history.currentTitle, "Crop to Selection", "crop lands in history")
    check(doc.history.canUndo, "so it can be undone")
    doc.undo()
    equal(doc.width, 20, "undo brings the canvas back")
    equal(doc.height, 20, "at its full height")
    check((pixel(doc, 18, 18)?.a ?? 0) > 200, "with the pixels the crop threw away")
}

windowSection("the layers buttons say what they do") {
    let panel = LayersPanel()
    let hinting = panel.buttonStrip.compactMap { $0 as? HintingButton }
    equal(hinting.count, panel.buttonStrip.count, "every strip button hints")
    check(hinting.allSatisfy { $0.toolTip?.isEmpty == false }, "and keeps its tooltip")
    check(hinting.allSatisfy { $0.hint == $0.toolTip }, "with the same wording")

    equal(panel.hintText, "", "the hint line starts empty")
    hinting.first?.onHint?(hinting.first?.hint)
    equal(panel.hintText, "Add a new layer", "entering a button explains it")
    hinting.first?.onHint?(nil)
    equal(panel.hintText, "", "and leaving clears it")
}

windowSection("the layers palette folds a group away") {
    let doc = Document(width: 8, height: 8, background: nil)
    doc.addLayer(named: "B")
    doc.drop(subtreeAt: 1, onto: 0)
    let panel = LayersPanel()
    panel.attach(doc)
    equal(panel.visibleRows.count, 3, "every entry shows while the group is open")
    equal(panel.visibleRows.first, 2, "top-most first")

    doc.layers[2].isCollapsed = true
    panel.reload()
    equal(panel.visibleRows, [2], "collapsing hides the members")

    doc.layers[2].isCollapsed = false
    panel.reload()
    equal(panel.visibleRows.count, 3, "expanding brings them back")
}

section("blur and sharpen brushes")
do {
    let doc = Document(width: 40, height: 20, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: .black)
    layer.context.setFillColor(NSColor.white.cgColor)
    layer.context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
    equal(PixelOps.sample(layer, x: 19, y: 10)?.r ?? 99, 0, "the edge is hard to start")

    PixelOps.blurDab(layer: layer, at: CGPoint(x: 20, y: 10), diameter: 12,
                     strength: 1, hardness: 1)
    let softened = PixelOps.sample(layer, x: 19, y: 10)?.r ?? 0
    check(softened > 20, "blur bleeds the white side across")
    check(softened < 235, "without flooding it")

    // Sharpening the same spot pushes the two sides apart again.
    let before = PixelOps.sample(layer, x: 22, y: 10)?.r ?? 0
    PixelOps.sharpenDab(layer: layer, at: CGPoint(x: 20, y: 10), diameter: 12,
                        strength: 1, hardness: 1)
    let after = PixelOps.sample(layer, x: 22, y: 10)?.r ?? 0
    check(after > before, "sharpen drives the light side lighter")

    // Strength scales the effect rather than switching it on and off.
    let gentleDoc = Document(width: 40, height: 20, background: nil)
    guard let gentle = gentleDoc.selectedLayer else { fatalError("no layer") }
    gentle.fill(with: .black)
    gentle.context.setFillColor(NSColor.white.cgColor)
    gentle.context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
    PixelOps.blurDab(layer: gentle, at: CGPoint(x: 20, y: 10), diameter: 12,
                     strength: 0.2, hardness: 1)
    let light = PixelOps.sample(gentle, x: 19, y: 10)?.r ?? 0
    check(light < softened, "a weaker dab moves the pixels less")
}

section("smudge pulls color along")
do {
    let doc = Document(width: 40, height: 20, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: .red)
    layer.context.setFillColor(NSColor.blue.cgColor)
    layer.context.fill(CGRect(x: 0, y: 0, width: 12, height: 20))
    equal(PixelOps.sample(layer, x: 20, y: 10)?.b ?? 99, 0, "the far side is pure red")

    let settings = ToolSettings()
    settings.tool = .smudge
    settings.brushWidth = 10
    settings.brushStrength = 1
    settings.hardness = 1
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.mouseDown(at: CGPoint(x: 8, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 20, y: 10), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 20, y: 10), modifiers: [])

    check((PixelOps.sample(layer, x: 18, y: 10)?.b ?? 0) > 40, "blue is dragged into the red")
    check((PixelOps.sample(layer, x: 35, y: 10)?.b ?? 99) < 20, "but not past where the stroke stopped")
    equal(doc.history.currentTitle, "Smudge", "and the stroke is one undo step")
}

section("a group is not a canvas")
do {
    let doc = Document(width: 20, height: 20, background: nil)
    doc.selectedLayer?.fill(with: .red)
    doc.groupSelected()
    check(doc.selectedLayer?.isGroup == true, "the group is selected")
    check(doc.selectedRasterLayer == nil, "and offers nothing to paint on")

    let settings = ToolSettings()
    settings.tool = .paintbrush
    settings.brushWidth = 10
    let engine = ToolEngine(doc: doc, settings: settings)
    var status = ""
    engine.onStatus = { status = $0 }
    engine.primaryColor = .blue
    engine.mouseDown(at: CGPoint(x: 10, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 12, y: 12), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 12, y: 12), modifiers: [])
    check(status.contains("group"), "painting says why it did nothing")
    check((pixel(doc, 10, 10)?.b ?? 255) < 40, "and nothing is painted")
    check(!doc.history.canUndo || doc.history.currentTitle != "Paintbrush",
          "no empty step lands in history")

    // Selection tools still work on a group: they belong to the document.
    settings.tool = .rectangleSelect
    engine.mouseDown(at: CGPoint(x: 2, y: 2), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 8, y: 8), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 8, y: 8), modifiers: [])
    check(doc.selectionPath != nil, "selecting works with a group selected")

    // And the document commands refuse rather than paint into nothing.
    check(!doc.eraseSelection(), "erase does nothing on a group")
    check(doc.paste(Layer(width: 4, height: 4, name: "clip").image!) == nil,
          "and neither does paste")
}

section("healing brush through the engine")
do {
    let doc = Document(width: 60, height: 30, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: NSColor(white: 0.45, alpha: 1))
    layer.context.setFillColor(NSColor.black.cgColor)
    layer.context.fill(CGRect(x: 28, y: 12, width: 6, height: 6))

    let settings = ToolSettings()
    settings.tool = .healingBrush
    settings.brushWidth = 12
    let engine = ToolEngine(doc: doc, settings: settings)

    // No source set yet: the first stroke must not change anything.
    engine.mouseDown(at: CGPoint(x: 31, y: 15), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 31, y: 15), modifiers: [])
    check((PixelOps.sample(layer, x: 31, y: 15)?.r ?? 255) < 20, "no source, no heal")

    // ⌥-click sets the source, then a drag heals.
    engine.mouseDown(at: CGPoint(x: 10, y: 15), rightButton: false, modifiers: [.option])
    engine.mouseDown(at: CGPoint(x: 31, y: 15), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 32, y: 15), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 32, y: 15), modifiers: [])
    check((PixelOps.sample(layer, x: 31, y: 15)?.r ?? 0) > 60, "the drag heals the blemish")
    equal(doc.history.currentTitle, "Healing Brush", "and lands in history")

    // Spot healing needs no source at all.
    let spotDoc = Document(width: 60, height: 30, background: nil)
    guard let spot = spotDoc.selectedLayer else { fatalError("no layer") }
    spot.fill(with: NSColor(white: 0.45, alpha: 1))
    spot.context.setFillColor(NSColor.black.cgColor)
    spot.context.fill(CGRect(x: 28, y: 12, width: 6, height: 6))
    let spotSettings = ToolSettings()
    spotSettings.tool = .spotHealing
    spotSettings.brushWidth = 12
    let spotEngine = ToolEngine(doc: spotDoc, settings: spotSettings)
    spotEngine.mouseDown(at: CGPoint(x: 31, y: 15), rightButton: false, modifiers: [])
    spotEngine.mouseUp(at: CGPoint(x: 31, y: 15), modifiers: [])
    check((PixelOps.sample(spot, x: 31, y: 15)?.r ?? 0) > 60, "spot healing needs no source")
}

section("healing brush")
do {
    // A light half and a dark half, with a black blemish in the dark one.
    let doc = Document(width: 48, height: 24, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: NSColor(white: 0.30, alpha: 1))
    layer.context.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
    layer.context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
    layer.context.setFillColor(NSColor.black.cgColor)
    layer.context.fillEllipse(in: CGRect(x: 33, y: 9, width: 6, height: 6))
    check((PixelOps.sample(layer, x: 36, y: 12)?.r ?? 255) < 20, "the blemish is there to start")

    // Healing from the light half must not drag the light tone across: the
    // texture comes from the source, the tone from where the dab lands.
    let healed = PixelOps.heal(layer: layer, at: CGPoint(x: 36, y: 12), diameter: 8,
                               offset: CGSize(width: -24, height: 0), hardness: 0.8)
    check(healed, "the dab lands inside the canvas")
    let after = PixelOps.sample(layer, x: 36, y: 12)?.r ?? 0
    check(after > 30, "the blemish is gone")
    check(after < 150, "and the light source tone did not come with it")

    // A dab in the corner still works: the edge pixels stand in for what
    // hangs over the side.
    check(PixelOps.heal(layer: layer, at: CGPoint(x: 1, y: 1), diameter: 20,
                        offset: CGSize(width: 6, height: 6), hardness: 1),
          "a dab in the corner still heals")
    check(PixelOps.sample(layer, x: 1, y: 1) != nil, "and leaves the corner readable")
    check(!PixelOps.heal(layer: layer, at: CGPoint(x: -100, y: -100), diameter: 8,
                         offset: .zero, hardness: 1),
          "a dab right off the canvas does nothing")
}

section("spot healing picks its own source")
do {
    let doc = Document(width: 40, height: 40, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: NSColor(white: 0.55, alpha: 1))
    // A busy corner and a calm one: the calm patch is the better source.
    layer.context.setFillColor(NSColor.red.cgColor)
    for i in 0..<10 {
        layer.context.fill(CGRect(x: CGFloat(i) * 2, y: 0, width: 1, height: 40))
    }
    layer.context.setFillColor(NSColor.black.cgColor)
    layer.context.fillEllipse(in: CGRect(x: 26, y: 18, width: 6, height: 6))

    let offset = PixelOps.bestHealSource(layer: layer, at: CGPoint(x: 29, y: 21), diameter: 8)
    check(offset != nil, "spot healing finds somewhere to sample")
    if let offset {
        check(offset.width >= 0, "and steers away from the striped side")
        PixelOps.heal(layer: layer, at: CGPoint(x: 29, y: 21), diameter: 8,
                      offset: offset, hardness: 0.8)
        let after = PixelOps.sample(layer, x: 29, y: 21)?.r ?? 0
        check(after > 100, "the spot is healed back towards the surrounding tone")
    }
}

section("healing keeps the layer clean")
do {
    let doc = Document(width: 20, height: 20, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: NSColor(white: 0.5, alpha: 1))
    PixelOps.heal(layer: layer, at: CGPoint(x: 10, y: 10), diameter: 6,
                  offset: CGSize(width: 4, height: 0), hardness: 1)
    check(layer.context.ctm == Layer.makeContext(width: 20, height: 20).ctm,
          "healing leaves no transform behind")
    check(layer.context.interpolationQuality == .high,
          "and no resampling setting behind")
}

section("a paste lands on the layer that is selected when it drops")
do {
    let doc = Document(width: 20, height: 20, background: nil)
    doc.addLayer(named: "Second")
    doc.selectedLayerIndex = 0
    let settings = ToolSettings()
    let engine = ToolEngine(doc: doc, settings: settings)

    let clip = Layer(width: 6, height: 6, name: "clip")
    clip.fill(with: .red)
    guard let image = clip.image else { fatalError("no clip") }

    engine.beginFloatingPaste(image, at: CGPoint(x: 5, y: 5))
    check(engine.hasFloatingPixels, "the paste floats before it lands")

    // Switching layers while it floats is the whole point: it should land on
    // the layer chosen at drop time, not the one that was current at paste.
    doc.selectedLayerIndex = 1
    check(engine.commitFloatingPixels(), "the paste drops")
    check((PixelOps.sample(doc.layers[1], x: 7, y: 7)?.r ?? 0) > 200, "on the layer picked afterwards")
    equal(PixelOps.sample(doc.layers[0], x: 7, y: 7)?.a ?? 99, 0, "and not on the one it was pasted over")
}

windowSection("clicking a layer row selects that layer") {
    let doc = Document(width: 8, height: 8, background: nil)
    doc.addLayer(named: "Middle")
    doc.addLayer(named: "Top")
    let panel = LayersPanel()
    panel.attach(doc)

    // Rows run top-first, so the last row is the bottom layer.
    equal(panel.visibleRows, [2, 1, 0], "three rows, top-most first")
    panel.selectRow(2)
    equal(doc.selectedLayerIndex, 0, "the bottom row selects the bottom layer")
    panel.selectRow(0)
    equal(doc.selectedLayerIndex, 2, "and the top row the top layer")

    // A layer added behind the panel's back must not leave the mapping stale.
    doc.addLayer(named: "Fourth")
    panel.selectRow(3)
    equal(doc.selectedLayerIndex, 0, "a row still means what it shows after the stack changes")
}

section("a floating paste sits in its layer's place")
do {
    // Bottom layer gets the paste; the layer above it is opaque white, so a
    // paste drawn on top of everything would show through where it must not.
    let doc = Document(width: 20, height: 20, background: nil)
    doc.selectedLayer?.fill(with: .white)
    doc.addLayer(named: "Cover")
    doc.selectedLayer?.context.setFillColor(NSColor.green.cgColor)
    doc.selectedLayer?.context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
    doc.commit("Cover")
    doc.selectedLayerIndex = 0

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    let clip = Layer(width: 20, height: 20, name: "clip")
    clip.fill(with: .red)
    engine.beginFloatingPaste(clip.image!, at: .zero)

    // Where the upper layer covers, it wins; elsewhere the paste shows.
    check((pixel(doc, 10, 5)?.g ?? 0) > 200, "the layer above still covers the paste")
    check((pixel(doc, 10, 5)?.r ?? 255) < 80, "so none of it shows through")
    check((pixel(doc, 10, 15)?.r ?? 0) > 200, "and the paste shows where nothing covers it")

    // Dropping it changes nothing about what is on screen.
    check(engine.commitFloatingPixels(), "the paste drops")
    check((pixel(doc, 10, 5)?.g ?? 0) > 200, "the cover still covers")
    check((pixel(doc, 10, 15)?.r ?? 0) > 200, "and the paste is where it looked")
}

windowSection("a paste shows up in the palette") {
    let doc = Document(width: 40, height: 40, background: .white)
    doc.addLayer(named: "Second")
    doc.selectedLayerIndex = 0

    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)
    // Whatever the pasteboard is carrying may be bigger than this canvas, and
    // a modal has nobody to click it in a test run.
    controller.oversizePastePolicy = .keep
    let panel = hub.layersPanel
    let thumbSize = NSSize(width: 34, height: 34)
    let before = doc.layers[0].thumbnail(size: thumbSize)

    let clip = Layer(width: 10, height: 10, name: "clip")
    clip.fill(with: .red)
    controller.engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 5, y: 5))
    check(controller.engine.hasFloatingPixels, "the paste is floating")

    check(controller.engine.commitFloatingPixels(), "and drops into the layer")
    controller.refreshPanels()
    check(doc.layers[0].thumbnail(size: thumbSize) !== before, "the palette thumbnail is redrawn")
    equal(panel.visibleRows, [1, 0], "with the stack still in order, top first")

    // Pasting into a new layer puts it above the one that was selected, and
    // the palette shows it there straight away.
    controller.pasteIntoNewLayer(nil)
    controller.commitPendingEdits()
    equal(doc.layers.count, 3, "the new layer is in the stack")
    equal(panel.visibleRows.count, 3, "and the palette lists all three")
    equal(panel.visibleRows.first, 2, "top-most row is the top-most layer")
    equal(doc.layers[doc.selectedLayerIndex].name, "Pasted Layer", "with the pasted layer selected")
    check((pixel(doc, 7, 7)?.r ?? 0) > 200, "and the pasted pixels on the canvas")
    controller.window?.close()
}

windowSection("cut and paste follow the selected layer") {
    let doc = Document(width: 20, height: 20, background: nil)
    doc.selectedLayer?.fill(with: .red)
    doc.addLayer(named: "Second")
    doc.selectedLayerIndex = 0

    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)
    controller.doc.selectionPath = CGPath(rect: CGRect(x: 4, y: 4, width: 8, height: 8), transform: nil)

    controller.cut(nil)
    equal(PixelOps.sample(doc.layers[0], x: 8, y: 8)?.a ?? 99, 0, "cutting empties the source")

    // Pick the other layer the way the palette does, then paste.
    hub.layersPanel.selectRow(0)
    equal(doc.selectedLayerIndex, 1, "the palette selected the upper layer")

    controller.paste(nil)
    controller.commitPendingEdits()
    check((PixelOps.sample(doc.layers[1], x: 8, y: 8)?.r ?? 0) > 200, "the paste lands on the chosen layer")
    equal(PixelOps.sample(doc.layers[0], x: 8, y: 8)?.a ?? 99, 0, "and not back where it was cut from")
    controller.window?.close()
}

windowSection("layer thumbnails are cached and downsampled") {
    let doc = Document(width: 512, height: 512, background: .white)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    let size = NSSize(width: 34, height: 34)

    let first = layer.thumbnail(size: size)
    check(layer.thumbnail(size: size) === first, "a second ask reuses the rendering")
    // One slot: asking for another size drops what was cached.
    check(layer.thumbnail(size: NSSize(width: 48, height: 48)) !== first, "a different size is its own")

    // Drawing into the layer is what makes a thumbnail stale.
    let base = layer.thumbnail(size: size)
    layer.fill(with: .red)
    check(layer.thumbnail(size: size) !== base, "painting invalidates it")
    let painted = layer.thumbnail(size: size)
    check(layer.thumbnail(size: size) === painted, "and the new one is kept until the next edit")

    // The two-step downsample has to land on the same picture, not a blank.
    guard let full = layer.image, let small = Layer.downsampled(full, fitting: size) else {
        check(false, "downsampling produced nothing"); fatalError("no thumbnail")
    }
    equal(small.width, 34, "downsampled to the size asked for")
    let probe = Layer(width: 34, height: 34, name: "probe")
    probe.draw(image: small)
    let pixel = PixelOps.sample(probe, x: 17, y: 17)
    check((pixel?.r ?? 0) > 200 && (pixel?.g ?? 255) < 80, "and keeps the colour it was")

    // Small images are handed back untouched rather than resampled twice.
    check(Layer.downsampled(probe.image!, fitting: NSSize(width: 64, height: 64)) === probe.image! ||
          Layer.downsampled(probe.image!, fitting: NSSize(width: 64, height: 64)).map { $0.width == 34 } == true,
          "an image already smaller than the target is left alone")
}

section("selections are steps in the history")
do {
    let doc = Document(width: 100, height: 100, background: .white)
    let settings = ToolSettings()
    settings.tool = .rectangleSelect
    let engine = ToolEngine(doc: doc, settings: settings)
    let steps = doc.history.entries.count

    engine.mouseDown(at: CGPoint(x: 10, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 40, y: 40), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 40, y: 40), modifiers: [])
    equal(doc.history.entries.count, steps + 1, "the drag lands in the history")
    equal(doc.history.currentTitle, "Rectangle Select", "named after the tool that made it")
    equal(doc.selectionPath?.boundingBoxOfPath.width ?? 0, 30, "and selects what was dragged over")

    // A second selection, then undo back through both.
    engine.mouseDown(at: CGPoint(x: 60, y: 60), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 90, y: 90), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 90, y: 90), modifiers: [])
    equal(doc.selectionPath?.boundingBoxOfPath.minX ?? 0, 60, "the second selection replaced the first")

    doc.undo()
    equal(doc.selectionPath?.boundingBoxOfPath.minX ?? -1, 10, "undo brings the first selection back")
    doc.undo()
    check(doc.selectionPath == nil, "and undoing again leaves nothing selected")
    doc.redo()
    equal(doc.selectionPath?.boundingBoxOfPath.minX ?? -1, 10, "redo puts it back")

    // Selecting costs no pixels: the layers are all unchanged.
    if let last = doc.history.entries.last {
        for state in last.layers {
            if case .unchanged = state.pixels.content { continue }
            check(false, "a selection step should copy no pixels")
        }
    }

    // Adding to a selection says so, and so do the document-wide commands.
    settings.selectionMode = .union
    engine.mouseDown(at: CGPoint(x: 60, y: 60), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 80, y: 80), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 80, y: 80), modifiers: [])
    equal(doc.history.currentTitle, "Add to Selection", "a union says what it did")

    doc.selectAll()
    equal(doc.history.currentTitle, "Select All", "select all is a step")
    doc.selectionPath = CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 20), transform: nil)
    doc.invertSelection()
    equal(doc.history.currentTitle, "Invert Selection", "so is inverting")
    doc.deselect()
    equal(doc.history.currentTitle, "Deselect", "so is dropping the selection")
    doc.undo()
    check(doc.selectionPath != nil, "undoing a deselect brings the selection back")

    // Nothing to do means no step: a deselect with nothing selected is not
    // worth an entry.
    doc.deselect()
    let settled = doc.history.entries.count
    doc.deselect()
    equal(doc.history.entries.count, settled, "deselecting twice adds nothing")
}

section("undo keeps only what changed")
do {
    let doc = Document(width: 200, height: 200, background: .white)
    let settings = ToolSettings()
    settings.tool = .pencil
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red

    func stroke(from a: CGPoint, to b: CGPoint) {
        engine.mouseDown(at: a, rightButton: false, modifiers: [])
        engine.mouseDragged(to: b, modifiers: [])
        engine.mouseUp(at: b, modifiers: [])
    }

    stroke(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 20))
    stroke(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 160, y: 120))

    // The steps carry a patch, not a copy of the canvas.
    let last = doc.history.entries.last
    if case .patch(_, let rect)? = last?.layers.first?.pixels.content {
        check(rect.width < 100 && rect.height < 100, "a small stroke keeps a small rectangle")
    } else {
        check(false, "a stroke should be stored as a patch")
    }
    // One base copy plus two small patches, not three canvases.
    check(doc.history.estimatedBytes < 200 * 200 * 4 * 2, "two strokes add far less than a canvas each")

    func isRed(_ x: Int, _ y: Int) -> Bool {
        guard let p = pixel(doc, x, y) else { return false }
        return p.r > 200 && p.g < 80
    }
    check(isRed(40, 20) && isRed(140, 120), "both strokes are there")

    doc.undo()
    check(isRed(40, 20), "undo leaves the first stroke")
    check(!isRed(140, 120), "and takes back the second")
    doc.undo()
    check(!isRed(40, 20), "a second undo takes back the first")
    check((pixel(doc, 40, 20)?.r ?? 0) > 200 && (pixel(doc, 40, 20)?.g ?? 0) > 200,
          "restoring the white it was painted over")

    doc.redo(); doc.redo()
    check(isRed(40, 20) && isRed(140, 120), "redo puts both back")

    // Jumping straight to an old step has to work as well as stepping.
    doc.jumpHistory(to: 0)
    check(!isRed(40, 20) && !isRed(140, 120), "jumping to the start clears both")
    doc.jumpHistory(to: doc.history.entries.count - 1)
    check(isRed(40, 20) && isRed(140, 120), "and jumping forward restores them")
}

section("a long run of edits still undoes")
do {
    // More strokes than the patch chain is allowed to grow, so the document
    // has to plant whole copies along the way.
    let doc = Document(width: 120, height: 120, background: .white)
    let settings = ToolSettings()
    settings.tool = .pencil
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .blue
    for i in 0..<20 {
        let y = CGFloat(5 + i * 5)
        engine.mouseDown(at: CGPoint(x: 10, y: y), rightButton: false, modifiers: [])
        engine.mouseDragged(to: CGPoint(x: 100, y: y), modifiers: [])
        engine.mouseUp(at: CGPoint(x: 100, y: y), modifiers: [])
    }
    func isBlue(_ i: Int) -> Bool {
        guard let p = pixel(doc, 50, 5 + i * 5) else { return false }
        // White has a full blue channel too, so the red one settles it.
        return p.b > 200 && p.r < 80
    }
    check((0..<20).allSatisfy(isBlue), "all twenty strokes landed")
    for _ in 0..<20 { doc.undo() }
    check((0..<20).allSatisfy { !isBlue($0) }, "and all twenty come back off")
    for _ in 0..<20 { doc.redo() }
    check((0..<20).allSatisfy(isBlue), "and go back on")
}

section("undo across changes the patches cannot describe")
do {
    let doc = Document(width: 100, height: 100, background: .white)
    doc.selectedLayer?.fill(with: .red)
    doc.commit("Fill")
    doc.addLayer(named: "Second")
    doc.selectedLayer?.fill(with: .green)
    doc.commit("Fill green")
    doc.crop(to: CGRect(x: 10, y: 10, width: 50, height: 50))
    equal(doc.width, 50, "the crop took")

    doc.undo()
    equal(doc.width, 100, "undo restores the canvas size")
    equal(doc.layers.count, 2, "with both layers")
    check((pixel(doc, 80, 80)?.g ?? 0) > 200, "and the pixels the crop discarded")

    doc.undo()
    equal(doc.layers.count, 2, "the step before that is where the layer was added")
    doc.undo()
    equal(doc.layers.count, 1, "another undo drops the added layer")
    check((pixel(doc, 50, 50)?.r ?? 0) > 200, "leaving the red fill")
}

section("the zoomed-out copy follows edits")
do {
    let doc = Document(width: 400, height: 400, background: .white)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }

    // Draw at a size that survives an eightfold shrink.
    layer.context.setFillColor(NSColor.red.cgColor)
    layer.context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    func shrunkPixel(_ x: Int, _ y: Int) -> PixelOps.RGBA? {
        guard let img = doc.composite(region: doc.bounds, pixelSize: CGSize(width: 50, height: 50))
        else { return nil }
        let probe = Layer(width: img.width, height: img.height, name: "probe")
        probe.draw(image: img)
        return PixelOps.sample(probe, x: x, y: y)
    }
    check((shrunkPixel(25, 10)?.r ?? 0) > 200, "the shrunk copy shows what was drawn")
    check((shrunkPixel(25, 10)?.g ?? 255) < 80, "in the right colour")
    check((shrunkPixel(25, 40)?.g ?? 0) > 200, "and the untouched half stays white")

    // Painting again must show up at the small size too, not a stale copy.
    layer.edit(CGRect(x: 0, y: 200, width: 400, height: 200)) { ctx in
        ctx.setFillColor(NSColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 200, width: 400, height: 200))
    }
    check((shrunkPixel(25, 40)?.b ?? 0) > 200, "a later edit reaches the shrunk copy")
    doc.commit("Paint")
    check((shrunkPixel(25, 10)?.r ?? 0) > 200, "and the older half is still there")
}

section("the checkerboard only draws what shows")
do {
    // Rendering a slice must give the same squares as rendering the lot: the
    // clip is an optimisation, not a different pattern.
    func board(clippedTo clip: CGRect?) -> Layer {
        let layer = Layer(width: 64, height: 64, name: "board")
        let ctx = layer.context
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.saveGState()
        if let clip { ctx.clip(to: clip) }
        drawCheckerboard(in: NSRect(x: 0, y: 0, width: 64, height: 64), cell: 8)
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        return layer
    }

    let whole = board(clippedTo: nil)
    let slice = board(clippedTo: CGRect(x: 16, y: 16, width: 32, height: 32))
    var compared = 0
    var same = 0
    for x in stride(from: 18, to: 46, by: 3) {
        for y in stride(from: 18, to: 46, by: 3) {
            compared += 1
            if PixelOps.sample(whole, x: x, y: y)?.r == PixelOps.sample(slice, x: x, y: y)?.r { same += 1 }
        }
    }
    equal(same, compared, "every square inside the clip matches the full drawing")
    check((PixelOps.sample(slice, x: 4, y: 4)?.a ?? 99) == 0, "and nothing is drawn outside it")

    // Both shades are present, so the comparison above is not comparing blanks.
    let shades = Set((0..<8).map { PixelOps.sample(whole, x: $0 * 8 + 4, y: 4)?.r ?? 0 })
    check(shades.count == 2, "the pattern still alternates")
}

section("floating pixels can be turned")
do {
    let doc = Document(width: 40, height: 40, background: nil)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.fill(with: .white)
    // One quadrant of the selection marked, so the turn is visible.
    layer.context.setFillColor(NSColor.red.cgColor)
    layer.context.fill(CGRect(x: 10, y: 20, width: 10, height: 10))

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    doc.selectionPath = CGPath(rect: CGRect(x: 10, y: 10, width: 20, height: 20), transform: nil)

    // Clicking with the tool lifts the pixels.
    engine.mouseDown(at: CGPoint(x: 20, y: 20), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 20, y: 20), modifiers: [])
    check(engine.hasFloatingPixels, "the selection floats")
    near(engine.floatingRotation, 0, 0.001, "and starts upright")

    guard let knob = engine.floatingRotationKnob() else {
        check(false, "the rotation knob is there to grab"); fatalError("no knob")
    }
    check(knob.y > engine.floatingRect.maxY, "the knob sits off the top edge")

    // Grab the knob and swing a quarter turn counter-clockwise.
    let centre = CGPoint(x: engine.floatingRect.midX, y: engine.floatingRect.midY)
    engine.mouseDown(at: knob, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: centre.x - 30, y: centre.y), modifiers: [])
    near(engine.floatingRotation, .pi / 2, 0.01, "the knob turns the pixels")

    // The outline follows the turn, so the ants sit on the pixels.
    let outline = doc.selectionPath?.boundingBoxOfPath ?? .zero
    near(outline.midX, centre.x, 1, "the outline stays centred on them")
    near(outline.width, 20, 1.5, "and a square box is still square after a quarter turn")

    engine.mouseUp(at: CGPoint(x: centre.x - 30, y: centre.y), modifiers: [])
    check(engine.commitFloatingPixels(), "the turned pixels drop into the layer")

    // The marked quadrant started top-left and a counter-clockwise turn puts
    // it bottom-left.
    func isRed(_ x: Int, _ y: Int) -> Bool {
        guard let p = PixelOps.sample(layer, x: x, y: y) else { return false }
        return p.r > 200 && p.g < 80
    }
    check(isRed(15, 15), "the marked corner has swung round to the bottom")
    check(!isRed(15, 25), "and left where it was")
    equal(doc.history.currentTitle, "Move Selected Pixels", "the turn is one undo step")
}

section("a turn can be snapped and undone")
do {
    let doc = Document(width: 40, height: 40, background: nil)
    doc.selectedLayer?.fill(with: .white)
    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    doc.selectionPath = CGPath(rect: CGRect(x: 8, y: 8, width: 16, height: 24), transform: nil)
    engine.mouseDown(at: CGPoint(x: 16, y: 20), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 16, y: 20), modifiers: [])

    guard let knob = engine.floatingRotationKnob() else {
        check(false, "knob"); fatalError("no knob")
    }
    let centre = CGPoint(x: engine.floatingRect.midX, y: engine.floatingRect.midY)
    engine.mouseDown(at: knob, rightButton: false, modifiers: [.shift])
    // A little past a quarter turn, which shift should pull back to it.
    let almost = CGFloat.pi / 2 + 0.12
    engine.mouseDragged(to: CGPoint(x: centre.x + cos(almost + .pi / 2) * 30,
                                    y: centre.y + sin(almost + .pi / 2) * 30),
                        modifiers: [.shift])
    let snapped = engine.floatingRotation
    near((snapped / (.pi / 12)).rounded() * (.pi / 12), snapped, 0.001, "shift snaps to 15° steps")

    // A taller-than-wide box turned on its side covers a wider outline.
    let box = doc.selectionPath?.boundingBoxOfPath ?? .zero
    check(box.width > 16, "the outline grows as the box turns")
    engine.mouseUp(at: centre, modifiers: [])
    engine.cancelFloatingPixels()
    check(!engine.hasFloatingPixels, "cancelling puts them back")
}

section("text lands in the box it was given")
do {
    let doc = Document(width: 120, height: 60, background: nil)
    let settings = ToolSettings()
    let engine = ToolEngine(doc: doc, settings: settings)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white
    ]
    let words = NSAttributedString(string: "wrap these words onto several lines", attributes: attrs)

    // A narrow box wraps; the ink stays inside it.
    engine.commitText(words, in: CGRect(x: 10, y: 10, width: 40, height: 40))
    func inked(_ rect: CGRect) -> Int {
        guard let layer = doc.selectedLayer else { return 0 }
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where (PixelOps.sample(layer, x: x, y: y)?.a ?? 0) > 30 {
                count += 1
            }
        }
        return count
    }
    check(inked(CGRect(x: 10, y: 10, width: 40, height: 40)) > 20, "the text is drawn in the box")
    equal(inked(CGRect(x: 55, y: 10, width: 60, height: 40)), 0, "and nothing spills to the right of it")
    equal(doc.history.currentTitle, "Text", "the text is one undo step")

    // A wider box needs fewer lines, so it reaches further right.
    let wide = Document(width: 120, height: 60, background: nil)
    let wideEngine = ToolEngine(doc: wide, settings: settings)
    wideEngine.commitText(words, in: CGRect(x: 10, y: 10, width: 100, height: 40))
    func rightmostInk(_ d: Document) -> Int {
        guard let layer = d.selectedLayer else { return 0 }
        var edge = 0
        for x in 0..<d.width {
            for y in 0..<d.height where (PixelOps.sample(layer, x: x, y: y)?.a ?? 0) > 30 { edge = max(edge, x) }
        }
        return edge
    }
    check(rightmostInk(wide) > rightmostInk(doc), "a wider box lets the line run further")

    // A group has no pixels to draw into.
    let grouped = Document(width: 40, height: 40, background: nil)
    grouped.groupSelected()
    let groupEngine = ToolEngine(doc: grouped, settings: settings)
    groupEngine.commitText(words, in: CGRect(x: 2, y: 2, width: 30, height: 30))
    check(grouped.history.currentTitle != "Text", "text refuses a group like every other paint tool")
}

windowSection("zooming keeps the pointer on the same pixel") {
    let doc = Document(width: 400, height: 400)
    let settings = ToolSettings()
    let engine = ToolEngine(doc: doc, settings: settings)
    let canvas = CanvasView(document: doc, engine: engine, settings: settings)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.documentView = canvas
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    canvas.zoom = 1
    canvas.layoutSubtreeIfNeeded()

    func imagePoint(under windowPoint: NSPoint) -> CGPoint {
        canvas.imagePoint(from: canvas.convert(windowPoint, from: nil))
    }

    // A point well off centre, but over the image: that is what has to stay put.
    let pointer = NSPoint(x: 200, y: 220)
    let before = imagePoint(under: pointer)
    canvas.setZoom(4, anchoredAt: pointer)
    canvas.layoutSubtreeIfNeeded()
    let after = imagePoint(under: pointer)
    near(after.x, before.x, 1, "the pixel under the pointer stays there across a zoom in")
    near(after.y, before.y, 1, "vertically too")

    canvas.setZoom(1, anchoredAt: pointer)
    canvas.layoutSubtreeIfNeeded()
    let back = imagePoint(under: pointer)
    near(back.x, before.x, 1, "and across a zoom back out")
    near(back.y, before.y, 1, "in both directions")

    // Near the image's own corner, which needs scrolling past the edge to hold.
    let corner = NSPoint(x: 160, y: 160)
    let cornerBefore = imagePoint(under: corner)
    canvas.setZoom(8, anchoredAt: corner)
    canvas.layoutSubtreeIfNeeded()
    let cornerAfter = imagePoint(under: corner)
    near(cornerAfter.x, cornerBefore.x, 2, "the canvas scrolls past its edge to hold a corner")
    near(cornerAfter.y, cornerBefore.y, 2, "in both directions")

    // Without an anchor the middle of the viewport is what holds still.
    canvas.setZoom(2, anchoredAt: nil)
    canvas.layoutSubtreeIfNeeded()
    let middle = NSPoint(x: scroll.contentView.documentVisibleRect.midX,
                         y: scroll.contentView.documentVisibleRect.midY)
    let centreBefore = canvas.imagePoint(from: middle)
    canvas.setZoom(6, anchoredAt: nil)
    canvas.layoutSubtreeIfNeeded()
    let after2 = NSPoint(x: scroll.contentView.documentVisibleRect.midX,
                         y: scroll.contentView.documentVisibleRect.midY)
    near(canvas.imagePoint(from: after2).x, centreBefore.x, 1, "an unanchored zoom holds the centre")
    near(canvas.imagePoint(from: after2).y, centreBefore.y, 1, "in both directions")
}

windowSection("the text box holds its place while zooming") {
    let doc = Document(width: 200, height: 200)
    let settings = ToolSettings()
    settings.tool = .text
    let engine = ToolEngine(doc: doc, settings: settings)
    let canvas = CanvasView(document: doc, engine: engine, settings: settings)
    canvas.setFrameSize(NSSize(width: 400, height: 400))

    let box = CGRect(x: 20, y: 30, width: 80, height: 40)
    let overlay = TextBoxOverlay(frame: .zero, font: .systemFont(ofSize: 12), color: .white)
    canvas.showTextBox(overlay, at: box)
    let atOne = overlay.frame

    canvas.zoom = 2
    equal(overlay.imageBox, box, "zooming does not move the box off its pixels")
    near(overlay.frame.width, atOne.width * 2 - TextBoxOverlay.handleReach * 2, 1.5,
         "the box on screen doubles with the canvas")
    near(overlay.textView.font?.pointSize ?? 0, 24, 0.5, "and the text is shown at the size it will paint")

    canvas.zoom = 1
    near(overlay.frame.minX, atOne.minX, 1, "and comes back to where it started")
    near(overlay.frame.minY, atOne.minY, 1, "in both directions")

    canvas.removeTextBox()
    check(canvas.textBox == nil, "the box goes away when it is committed")
}

section("layer groups")
do {
    // Bottom to top: Background, Middle, Top.
    let doc = Document(width: 8, height: 8, background: nil)
    doc.selectedLayer?.fill(with: .red)
    doc.addLayer(named: "Middle")
    doc.selectedLayer?.fill(with: .green)
    doc.addLayer(named: "Top")
    equal(doc.layers.count, 3, "three layers to start")

    // Dropping Top onto Middle wraps the pair in a group.
    doc.drop(subtreeAt: 2, onto: 1)
    equal(doc.layers.count, 4, "the group header joins the stack")
    check(doc.layers[3].isGroup, "and sits above its members")
    equal(doc.layers[3].depth, 0, "the group is top level")
    equal(doc.layers[1].name, "Middle", "the host stays below")
    equal(doc.layers[1].depth, 1, "nested inside the group")
    equal(doc.layers[2].name, "Top", "the dragged layer lands above it")
    equal(doc.layers[2].depth, 1, "nested too")
    equal(doc.childRange(ofGroupAt: 3), 1..<3, "the group knows its members")
    equal(doc.parentGroup(of: 1), 3, "and a member knows its group")

    // A group hides what it holds.
    doc.layers[3].isVisible = false
    check((pixel(doc, 4, 4)?.g ?? 255) < 40, "hiding the group hides its members")
    doc.layers[3].isVisible = true
    check((pixel(doc, 4, 4)?.g ?? 0) > 200, "showing it brings them back")

    // Opacity applies to the group as a whole, not to each member in turn.
    doc.layers[3].opacity = 0.5
    let blended = pixel(doc, 4, 4)
    check((blended?.r ?? 0) > 90 && (blended?.g ?? 0) > 90, "group opacity blends the pair over the red below")
    doc.layers[3].opacity = 1

    // Grouping is undoable like any other edit.
    equal(doc.history.currentTitle, "Group Layers", "grouping lands in history")
    doc.undo()
    equal(doc.layers.count, 3, "undo dissolves the group")
    check(doc.layers.allSatisfy { $0.depth == 0 }, "and flattens the nesting back")
    doc.redo()
    equal(doc.layers.count, 4, "redo brings it back")

    // Dragging a layer out of a group renests it at the top level.
    doc.moveSubtree(from: 2, to: 4, depth: 0)
    equal(doc.layers.count, 4, "nothing is lost moving out")
    equal(doc.layers[3].name, "Top", "the layer sits above the group")
    equal(doc.layers[3].depth, 0, "back at the top level")
    check(doc.layers[2].isGroup, "with the group beneath it")
    equal(doc.childRange(ofGroupAt: 2), 1..<2, "holding one member now")

    // Ungrouping leaves the members where they were.
    doc.ungroup(at: 2)
    equal(doc.layers.count, 3, "the header goes")
    check(doc.layers.allSatisfy { !$0.isGroup }, "no group left")
    check(doc.layers.allSatisfy { $0.depth == 0 }, "and nothing stays indented")
}

section("group operations")
do {
    let doc = Document(width: 8, height: 8, background: nil)
    doc.selectedLayer?.fill(with: .red)
    doc.addLayer(named: "Paint")
    doc.selectedLayer?.fill(with: .blue)
    doc.groupSelected()
    check(doc.layers[2].isGroup, "grouping the selection makes a folder")
    equal(doc.selectedLayerIndex, 2, "and selects it")

    // Adding a layer while a group is selected puts it inside.
    doc.addLayer(named: "Inside")
    equal(doc.layers[doc.selectedLayerIndex].name, "Inside", "the new layer is selected")
    equal(doc.layers[doc.selectedLayerIndex].depth, 1, "and lands inside the group")
    equal(doc.parentGroup(of: doc.selectedLayerIndex), 3, "under the same header")

    // Duplicating a group copies its contents too.
    doc.selectedLayerIndex = 3
    doc.duplicateSelectedLayer()
    equal(doc.layers.count, 7, "header and both members are copied")
    check(doc.layers[6].isGroup, "the copy is a group")
    equal(doc.childRange(ofGroupAt: 6).count, 2, "with the same two members")

    // Merging a group bakes it down to one raster layer.
    doc.selectedLayerIndex = 6
    doc.mergeLayerDown()
    equal(doc.layers.count, 5, "the group collapses into a layer")
    check(!doc.layers[4].isGroup, "which holds pixels")
    equal(doc.history.currentTitle, "Merge Group", "and says so in history")
    check((pixel(doc, 4, 4)?.b ?? 0) > 200, "keeping what the group drew")

    // Deleting a group takes its members with it.
    doc.selectedLayerIndex = 3
    let before = doc.layers.count
    doc.deleteSelectedLayer()
    equal(doc.layers.count, before - 3, "header and members go together")
}

section("groups survive a round trip")
do {
    let doc = Document(width: 6, height: 6, background: nil)
    doc.selectedLayer?.fill(with: .red)
    doc.addLayer(named: "Nested")
    doc.selectedLayer?.fill(with: .green)
    doc.drop(subtreeAt: 1, onto: 0)
    doc.layers[2].name = "Folder"
    doc.layers[2].opacity = 0.5
    doc.layers[2].isCollapsed = true

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("group-roundtrip.sketchy")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        try doc.writeNative(to: url)
        let read = try Document.openNative(url: url)
        equal(read.layers.count, 3, "every entry comes back")
        check(read.layers[2].isGroup, "the group is still a group")
        equal(read.layers[2].name, "Folder", "with its name")
        near(read.layers[2].opacity, 0.5, 0.01, "and its opacity")
        check(read.layers[2].isCollapsed, "and stays folded")
        equal(read.layers[0].depth, 1, "members keep their nesting")
        equal(read.layers[1].depth, 1, "both of them")
    } catch {
        check(false, "saving a grouped document failed: \(error)")
    }
}

section("moving a layer within its group")
do {
    let doc = Document(width: 4, height: 4, background: nil)
    doc.addLayer(named: "B")
    doc.addLayer(named: "C")
    doc.drop(subtreeAt: 2, onto: 1)          // group B and C
    // Stack is now: A, B, C, [Group]
    doc.selectedLayerIndex = 1               // B, the lower member
    doc.moveSelected(up: true)
    equal(doc.layers[2].name, "B", "the member moves up inside its group")
    equal(doc.layers[2].depth, 1, "and stays nested")
    check(doc.layers[3].isGroup, "the header stays on top")

    doc.selectedLayerIndex = 2               // B again, now the top member
    doc.moveSelected(up: true)
    equal(doc.layers[2].name, "B", "it will not climb out of its group")
}

section("image size anchor")
do {
    // A wide image resized into a square box keeps its shape when fitting.
    func fitted(anchor: CGPoint) -> Document {
        let doc = Document(width: 40, height: 20, background: nil)
        doc.selectedLayer?.fill(with: .red)
        doc.resizeImage(to: CGSize(width: 40, height: 40), anchor: anchor, fit: true)
        return doc
    }
    func opaque(_ doc: Document, _ x: Int, _ y: Int) -> Bool {
        (pixel(doc, x, y)?.a ?? 0) > 200
    }

    let top = fitted(anchor: CGPoint(x: 0.5, y: 1))
    check(opaque(top, 20, 35), "fitting to the top leaves the image up there")
    check(!opaque(top, 20, 5), "the bottom is padded")

    let bottom = fitted(anchor: CGPoint(x: 0.5, y: 0))
    check(opaque(bottom, 20, 5), "fitting to the bottom moves it down")
    check(!opaque(bottom, 20, 35), "the top is padded")

    // Stretching ignores the anchor and fills the whole canvas.
    let stretched = Document(width: 40, height: 20, background: nil)
    stretched.selectedLayer?.fill(with: .red)
    stretched.resizeImage(to: CGSize(width: 40, height: 40), anchor: CGPoint(x: 0, y: 1), fit: false)
    check(opaque(stretched, 20, 5) && opaque(stretched, 20, 35), "stretching fills the new size")
    equal(stretched.history.currentTitle, "Image Size", "one history step")
}

// MARK: - Selection move and resize

section("move selection tool")
do {
    let doc = Document(width: 100, height: 100)
    doc.selectionPath = CGPath(rect: CGRect(x: 20, y: 20, width: 40, height: 40), transform: nil)
    let settings = ToolSettings()
    settings.tool = .moveSelection
    let engine = ToolEngine(doc: doc, settings: settings)

    // Dragging the interior moves the outline.
    engine.mouseDown(at: CGPoint(x: 40, y: 40), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 55, y: 30), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 55, y: 30), modifiers: [])
    var box = doc.selectionPath?.boundingBoxOfPath ?? .zero
    near(box.minX, 35, 0.5, "selection moved right")
    near(box.minY, 10, 0.5, "selection moved down")
    near(box.width, 40, 0.5, "moving does not resize")

    // Dragging the top-right corner handle resizes it.
    doc.selectionPath = CGPath(rect: CGRect(x: 20, y: 20, width: 40, height: 40), transform: nil)
    let corner = engine.selectionHandles()[4]
    near(corner.x, 60, 0.5, "corner handle sits on the box")
    engine.mouseDown(at: corner, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 80, y: 100), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 80, y: 100), modifiers: [])
    box = doc.selectionPath?.boundingBoxOfPath ?? .zero
    near(box.minX, 20, 0.5, "the far edge stays put")
    near(box.minY, 20, 0.5, "the far edge stays put vertically")
    near(box.width, 60, 0.5, "width follows the handle")
    near(box.height, 80, 0.5, "height follows the handle")
    equal(doc.history.currentTitle, "Resize Selection", "resizing is its own history step")

    // An ellipse keeps its shape while being scaled.
    doc.selectionPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 20, height: 20), transform: nil)
    let edge = engine.selectionHandles()[3]
    engine.mouseDown(at: edge, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 40, y: 10), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 40, y: 10), modifiers: [])
    box = doc.selectionPath?.boundingBoxOfPath ?? .zero
    near(box.width, 40, 0.5, "the ellipse widened")
    near(box.height, 20, 0.5, "the untouched axis is unchanged")
    check(!(doc.selectionPath?.contains(CGPoint(x: 1, y: 19)) ?? true), "corners stay outside the ellipse")

    // Shift keeps the proportions.
    doc.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 40), transform: nil)
    let grow = engine.selectionHandles()[4]
    engine.mouseDown(at: grow, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 40, y: 50), modifiers: [.shift])
    engine.mouseUp(at: CGPoint(x: 40, y: 50), modifiers: [.shift])
    box = doc.selectionPath?.boundingBoxOfPath ?? .zero
    near(box.width / box.height, 0.5, 0.01, "shift preserves the aspect ratio")
}

section("paste selects what was pasted")
do {
    let doc = Document(width: 60, height: 60)
    let stamp = Layer(width: 10, height: 8, name: "clip")
    stamp.fill(with: .red)

    let pasted = doc.paste(stamp.image!)
    equal(pasted?.width ?? 0, 10, "pasted at its own size")
    equal(pasted?.origin.y ?? -1, 52, "lands in the top-left corner")

    let box = doc.selectionPath?.boundingBoxOfPath ?? .zero
    equal(box, pasted ?? .zero, "the pasted region becomes the selection")
    equal(doc.history.currentTitle, "Paste", "paste is one history step")
    equal(pixel(doc, 5, 55)?.r ?? 0, 255, "the pixels landed")

    // Pasting again with a selection lands on that selection.
    doc.selectionPath = CGPath(rect: CGRect(x: 20, y: 20, width: 30, height: 30), transform: nil)
    let second = doc.paste(stamp.image!)
    equal(second?.origin.x ?? -1, 20, "reuses the selection's left edge")
    equal(second?.origin.y ?? -1, 42, "aligns to the selection's top edge")
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, second ?? .zero, "selection follows the new paste")
}

// MARK: - Color entry

section("color wheel at zero brightness")
do {
    let wheel = ColorWheelView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    wheel.selection = .black
    wheel.brightness = 0

    // Halfway out to the right rim: hue 0, saturation 0.5.
    wheel.pick(at: CGPoint(x: 75, y: 50))
    let picked = wheel.selection.usingColorSpace(.deviceRGB)!
    check(picked.brightnessComponent > 0.9, "picking off a black wheel gives a visible color")
    check(wheel.brightness > 0.9, "and lifts the wheel's own value with it")
    equal(Int((picked.hueComponent * 360).rounded()) % 360, 0, "the hue is the one under the cursor")
    check(abs(wheel.saturation - 0.5) < 0.02, "as is the saturation")

    // The marker tracks the drag even when the color it makes has no hue.
    wheel.pick(at: CGPoint(x: 50, y: 85))
    check(abs(wheel.hue - 0.25) < 0.02, "dragging to the top moves the marker to a quarter turn")
    wheel.selection = .black
    check(abs(wheel.hue - 0.25) < 0.02, "and a black selection does not drag it back to the middle")
    check(wheel.saturation > 0.5, "the marker keeps its distance from the center too")
}

section("hex parsing and formatting")
do {
    equal(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1).hexString, "FF8000", "opaque color is six digits")
    equal(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5).hexString, "00000080", "alpha appends two digits")

    let long = NSColor.fromHex("#1E90FF")
    equal(long?.rgbaBytes.r ?? -1, 30, "leading # is ignored")
    equal(long?.rgbaBytes.g ?? -1, 144, "green parsed")
    equal(long?.rgbaBytes.b ?? -1, 255, "blue parsed")
    equal(long?.rgbaBytes.a ?? -1, 255, "no alpha means opaque")

    let short = NSColor.fromHex("f80")
    equal(short?.hexString ?? "", "FF8800", "shorthand expands")

    let withAlpha = NSColor.fromHex("FF000080")
    equal(withAlpha?.rgbaBytes.a ?? -1, 128, "eight digits carry alpha")

    check(NSColor.fromHex("nothex") == nil, "letters outside hex are rejected")
    check(NSColor.fromHex("FFFF") != nil, "four digits are RGBA shorthand")
    check(NSColor.fromHex("FFFFF") == nil, "five digits are not a color")
    check(NSColor.fromHex("") == nil, "empty text is not a color")

    // Round trip through the hex string.
    let original = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 0.75)
    let restored = NSColor.fromHex(original.hexString)
    equal(restored?.hexString ?? "", original.hexString, "hex survives a round trip")
}

section("rgba and hsv entry")
do {
    let color = NSColor.fromBytes(r: 300, g: -20, b: 128, a: 200)
    equal(color.rgbaBytes.r, 255, "high values clamp")
    equal(color.rgbaBytes.g, 0, "negative values clamp")
    equal(color.rgbaBytes.b, 128, "in-range values pass through")
    equal(color.rgbaBytes.a, 200, "alpha passes through")

    let red = NSColor.fromBytes(r: 255, g: 0, b: 0, a: 255)
    let hsv = red.hsvValues
    equal(hsv.h, 0, "red sits at hue 0")
    equal(hsv.s, 100, "red is fully saturated")
    equal(hsv.v, 100, "red is full value")

    let fromHSV = NSColor.fromHSV(h: 120, s: 100, v: 100)
    equal(fromHSV.hexString, "00FF00", "hue 120 is green")
    // 999 wraps to hue 279, saturation and value clamp to 100%.
    equal(NSColor.fromHSV(h: 999, s: 999, v: 999).hexString, "A600FF", "out-of-range HSV wraps and clamps")
}

windowSection("a selection follows whichever layer is picked") {
    // The selection belongs to the document, not a layer, so switching rows in
    // the palette leaves it in place and the new layer is what it clips.
    let doc = Document(width: 20, height: 20, background: .white)
    doc.addLayer(named: "Second")
    doc.selectedLayerIndex = 0

    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)
    let box = CGRect(x: 4, y: 4, width: 8, height: 8)
    doc.selectionPath = CGPath(rect: box, transform: nil)

    hub.layersPanel.selectRow(0)
    equal(doc.selectedLayerIndex, 1, "the palette switched to the upper layer")
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, box, "and the selection is untouched")

    // An edit on the newly picked layer is clipped by that same selection.
    controller.fillSelection(nil)
    check((PixelOps.sample(doc.layers[1], x: 8, y: 8)?.a ?? 0) > 200, "a fill lands inside the selection")
    equal(PixelOps.sample(doc.layers[1], x: 1, y: 1)?.a ?? 99, 0, "and nothing outside it")
    controller.window?.close()
}

windowSection("⏎ renames the selected layer in place") {
    let doc = Document(width: 20, height: 20, background: .white)
    doc.addLayer(named: "Second")

    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)
    let panel = hub.layersPanel
    let steps = doc.history.entries.count

    panel.selectRow(0)
    equal(doc.selectedLayerIndex, 1, "the upper layer is selected")
    check(panel.beginRename(), "⏎ opens the name for editing")
    check(panel.commitRename("Sky"), "and typing a new one keeps it")
    equal(doc.layers[1].name, "Sky", "the layer took the new name")
    equal(doc.history.currentTitle, "Rename Layer", "as one undoable step")
    equal(doc.history.entries.count, steps + 1, "and only one step")

    check(doc.undo(), "the rename undoes")
    equal(doc.layers[1].name, "Second", "back to the old name")

    // An empty name, or the same one again, is not worth a history step.
    panel.selectRow(0)
    check(panel.beginRename(), "editing opens again")
    check(!panel.commitRename("   "), "a blank name is refused")
    equal(doc.layers[1].name, "Second", "and the name is left alone")
    controller.window?.close()
}

section("handles stay reachable off the canvas")
do {
    // A box dragged past the edge keeps its handles out there: they are what
    // you grab to pull it back or resize it.
    let doc = Document(width: 20, height: 20)
    let clip = Layer(width: 10, height: 10, name: "clip")
    clip.fill(with: .red)
    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.beginFloatingPaste(clip.image!, at: CGPoint(x: 15, y: 15))

    let corner = engine.floatingHandles()[4]
    check(!doc.bounds.contains(corner), "the far corner sits outside the canvas")

    // Drawing the chrome is what makes it visible; the canvas draws it outside
    // its own clip, so a context no larger than the document still gets it.
    let probe = Layer(width: 20, height: 20, name: "probe")
    engine.drawChrome(in: probe.context, scale: 1)

    // Grabbing that outside corner resizes rather than moving the whole box.
    engine.mouseDown(at: corner, rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 30, y: 30), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 30, y: 30), modifiers: [])
    near(engine.floatingRect.minX, 15, 0.6, "the anchored edge stayed put")
    near(engine.floatingRect.width, 15, 0.6, "and the box grew past the edge")
}

windowSection("the Edit menu pastes at each scale") {
    let doc = Document(width: 40, height: 40, background: .white)
    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)

    // Put a wide clip on the pasteboard the way Copy does.
    let source = Document(width: 20, height: 10, background: .red)
    let hub2 = PaletteHub()
    let sourceController = MainWindowController(doc: source, hub: hub2)
    sourceController.selectAll(nil)
    sourceController.copy(nil)

    controller.pasteStretchedToCanvas(nil)
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, doc.bounds, "stretching filled the canvas")
    equal(doc.history.currentTitle, "Paste", "as one paste step")

    check(doc.undo(), "and it undoes")
    controller.pasteFitToCanvas(nil)
    equal(doc.selectionPath?.boundingBoxOfPath ?? .zero, CGRect(x: 0, y: 10, width: 40, height: 20),
          "fitting scaled it without distorting")

    // A group holds no pixels, so neither scale may paste into one.
    doc.addLayer(named: "Holder")
    doc.groupSelected()
    if doc.selectedLayer?.isGroup == true {
        let steps = doc.history.entries.count
        controller.pasteStretchedToCanvas(nil)
        equal(doc.history.entries.count, steps, "a group takes no paste")
    }
    sourceController.window?.close()
    controller.window?.close()
}

section("exporting a flat image leaves the document alone")
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SketchyExport-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Two layers, so a flat export has something to merge.
    let doc = Document(width: 20, height: 20, background: .white)
    doc.addLayer(named: "Top")
    doc.selectedLayer?.context.setFillColor(NSColor.red.cgColor)
    doc.selectedLayer?.context.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
    doc.commit("Paint")

    let native = dir.appendingPathComponent("art.sketchy")
    try? doc.write(to: native)
    equal(doc.fileURL, native, "saving adopted the file")
    check(!doc.isDirty, "and marked it clean")

    // Exporting is not saving: the document still belongs to its own file.
    let flat = dir.appendingPathComponent("export.png")
    doc.isDirty = true
    do { try doc.export(to: flat) } catch { check(false, "export threw \(error)") }
    check(FileManager.default.fileExists(atPath: flat.path), "the flat file was written")
    equal(doc.fileURL, native, "the document kept its own file")
    check(doc.isDirty, "and unsaved work is still unsaved")
    equal(doc.layers.count, 2, "the layers are untouched")

    // What came out is the composite, both layers merged.
    let reopened = try? Document.open(url: flat)
    check(reopened != nil, "the exported file reads back")
    if let reopened {
        equal(reopened.layers.count, 1, "the export is one flat layer")
        equal(reopened.width, 20, "at the document's size")
        equal(PixelOps.sample(reopened.layers[0], x: 5, y: 10)?.r ?? 0, 255, "the top layer is in it")
        check(Int(PixelOps.sample(reopened.layers[0], x: 5, y: 10)?.g ?? 255) < 60, "as red")
        equal(PixelOps.sample(reopened.layers[0], x: 15, y: 10)?.g ?? 0, 255, "and the background under it")
    }

    // A hidden layer is left out, matching what the canvas shows.
    doc.layers[1].isVisible = false
    let hidden = dir.appendingPathComponent("hidden.png")
    do { try doc.export(to: hidden) } catch { check(false, "export threw \(error)") }
    if let out = try? Document.open(url: hidden) {
        equal(PixelOps.sample(out.layers[0], x: 5, y: 10)?.g ?? 0, 255,
              "a hidden layer is not exported")
    }

    // The extension picks the encoder.
    let jpeg = dir.appendingPathComponent("art.jpg")
    do { try doc.export(to: jpeg) } catch { check(false, "jpeg export threw \(error)") }
    check((try? Data(contentsOf: jpeg))?.starts(with: [0xFF, 0xD8]) == true, "a .jpg is really JPEG")
    let png = dir.appendingPathComponent("art.png")
    do { try doc.export(to: png) } catch { check(false, "png export threw \(error)") }
    check((try? Data(contentsOf: png))?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true,
          "and a .png is really PNG")
}

section("recolor targets a color off the canvas")
do {
    // Three bands: green, blue, white. Recolor must take the one it is aimed
    // at and leave the others alone.
    let doc = Document(width: 30, height: 30, background: .white)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    layer.context.setFillColor(NSColor.green.cgColor)
    layer.context.fill(CGRect(x: 0, y: 0, width: 30, height: 10))
    layer.context.setFillColor(NSColor.blue.cgColor)
    layer.context.fill(CGRect(x: 0, y: 10, width: 30, height: 10))
    doc.commit("Bands")

    let settings = ToolSettings()
    settings.tool = .recolor
    settings.brushWidth = 30
    settings.tolerance = 0.1
    settings.recolorTarget = .sampledColor
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red

    // Brushing the green band replaces green, not the blue above it.
    engine.mouseDown(at: CGPoint(x: 15, y: 5), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 15, y: 5), modifiers: [])
    equal(PixelOps.sample(layer, x: 15, y: 5)?.r ?? 0, 255, "the sampled band went red")
    check(Int(PixelOps.sample(layer, x: 15, y: 5)?.g ?? 255) < 60, "and is no longer green")
    check((PixelOps.sample(layer, x: 15, y: 15)?.b ?? 0) > 200, "the blue band is untouched")
    equal(doc.history.currentTitle, "Recolor", "one history step")

    // Aimed at blue instead, the same brush takes blue — nothing about the
    // tool is fixed to white.
    engine.mouseDown(at: CGPoint(x: 15, y: 15), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 15, y: 15), modifiers: [])
    equal(PixelOps.sample(layer, x: 15, y: 15)?.r ?? 0, 255, "blue was replaced too")
    check(Int(PixelOps.sample(layer, x: 15, y: 15)?.b ?? 255) < 60, "and is no longer blue")
    // White was never targeted, so it is still there.
    equal(PixelOps.sample(layer, x: 15, y: 25)?.g ?? 0, 255, "white was left alone")
}

section("recolor keeps replacing the color it started on")
do {
    // Sampling every dab would chase the pixels the stroke just laid down, so
    // the target is locked in at mouse-down.
    let doc = Document(width: 40, height: 10, background: .white)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    let settings = ToolSettings()
    settings.tool = .recolor
    settings.brushWidth = 8
    settings.tolerance = 0.1
    settings.recolorTarget = .sampledColor
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red

    engine.mouseDown(at: CGPoint(x: 4, y: 5), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 36, y: 5), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 36, y: 5), modifiers: [])
    // Every step of the drag replaced white, so the whole band is red.
    for x in [6, 14, 22, 30, 34] {
        equal(PixelOps.sample(layer, x: x, y: 5)?.r ?? 0, 255, "x=\(x) was recolored")
        check(Int(PixelOps.sample(layer, x: x, y: 5)?.g ?? 255) < 60, "and is red at x=\(x)")
    }
}

section("a fast recolor drag leaves no gaps")
do {
    // One pointer event jumping the width of the canvas: without stepping, the
    // stroke would only touch the two ends.
    let doc = Document(width: 60, height: 20, background: .white)
    guard let layer = doc.selectedLayer else { fatalError("no layer") }
    let settings = ToolSettings()
    settings.tool = .recolor
    settings.brushWidth = 6
    settings.tolerance = 0.1
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red
    engine.secondaryColor = .white

    engine.mouseDown(at: CGPoint(x: 5, y: 10), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 55, y: 10), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 55, y: 10), modifiers: [])

    // Every point along the way is covered, not just where the events landed.
    for x in stride(from: 6, through: 54, by: 4) {
        equal(PixelOps.sample(layer, x: x, y: 10)?.r ?? 0, 255, "x=\(x) is covered")
        check(Int(PixelOps.sample(layer, x: x, y: 10)?.g ?? 255) < 60, "with no gap at x=\(x)")
    }

    // A diagonal jump is stepped too, and does not smear the corners of its
    // bounding box.
    let doc2 = Document(width: 40, height: 40, background: .white)
    guard let layer2 = doc2.selectedLayer else { fatalError("no layer") }
    let engine2 = ToolEngine(doc: doc2, settings: settings)
    engine2.primaryColor = .red
    engine2.secondaryColor = .white
    engine2.mouseDown(at: CGPoint(x: 5, y: 5), rightButton: false, modifiers: [])
    engine2.mouseDragged(to: CGPoint(x: 35, y: 35), modifiers: [])
    engine2.mouseUp(at: CGPoint(x: 35, y: 35), modifiers: [])
    equal(PixelOps.sample(layer2, x: 20, y: 20)?.r ?? 0, 255, "the diagonal is covered in the middle")
    equal(PixelOps.sample(layer2, x: 34, y: 6)?.g ?? 0, 255, "and the far corner is untouched")
}

section("a pending shape follows the current color")
do {
    // The preview and the commit both read the engine's colors, so a color
    // picked while the shape is still live is the one it lands in.
    let doc = Document(width: 30, height: 30, background: .white)
    let settings = ToolSettings()
    settings.tool = .shapes
    settings.shape = .rectangle
    settings.drawMode = .fill
    settings.fillStyle = .solidColor
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red
    engine.secondaryColor = .green

    engine.mouseDown(at: CGPoint(x: 5, y: 5), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 25, y: 25), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 25, y: 25), modifiers: [])
    check(engine.session != nil, "the shape is still live after the drag")

    // Draw the preview into a probe: it comes out in the colour set right now.
    let before = Layer(width: 30, height: 30, name: "before")
    engine.drawOverlay(in: before.context, scale: 1)
    check((PixelOps.sample(before, x: 15, y: 15)?.g ?? 0) > 200, "the preview fills with the secondary")

    // Change the fill colour with the shape still pending, then look again.
    engine.secondaryColor = .blue
    let after = Layer(width: 30, height: 30, name: "after")
    engine.drawOverlay(in: after.context, scale: 1)
    check((PixelOps.sample(after, x: 15, y: 15)?.b ?? 0) > 200, "the preview took the new colour")
    check(Int(PixelOps.sample(after, x: 15, y: 15)?.g ?? 255) < 60, "and dropped the old one")

    // Committing uses that same colour, not the one the shape started with.
    check(engine.commitSession(), "the shape commits")
    check((pixel(doc, 15, 15)?.b ?? 0) > 200, "and lands in the colour showing at the time")
}

section("a pending line follows the current color")
do {
    let doc = Document(width: 30, height: 30, background: .white)
    let settings = ToolSettings()
    settings.tool = .line
    settings.brushWidth = 6
    let engine = ToolEngine(doc: doc, settings: settings)
    engine.primaryColor = .red

    engine.mouseDown(at: CGPoint(x: 4, y: 15), rightButton: false, modifiers: [])
    engine.mouseDragged(to: CGPoint(x: 26, y: 15), modifiers: [])
    engine.mouseUp(at: CGPoint(x: 26, y: 15), modifiers: [])
    check(engine.session != nil, "the line is still live")

    engine.primaryColor = .blue
    check(engine.commitSession(), "the line commits")
    check((pixel(doc, 15, 15)?.b ?? 0) > 200, "in the colour set while it was pending")
    check(Int(pixel(doc, 15, 15)?.r ?? 255) < 60, "not the one it was drawn with")
}

section("the text overlay recolors what is already typed")
do {
    // The colour lives on the text storage as well as the view, so recoloring
    // has to touch both or text already typed keeps the old one.
    let overlay = TextBoxOverlay(frame: NSRect(x: 0, y: 0, width: 80, height: 24),
                                 font: .systemFont(ofSize: 12), color: .red)
    overlay.textView.string = "hi"
    check(overlay.textView.textColor == NSColor.red, "it starts in the colour it was made with")

    overlay.setColor(.blue)
    check(overlay.textView.textColor == NSColor.blue, "the view took the new colour")
    let painted = overlay.textView.textStorage?
        .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    check(painted == NSColor.blue, "and so did the text already typed")
}

section("lifted pixels land back on the layer they came from")
do {
    // A paste drops wherever the user picks, but lifted pixels were cut out of
    // a layer: that hole is theirs to fill, whatever the selection does next.
    let doc = Document(width: 20, height: 20, background: nil)
    doc.addLayer(named: "Second")
    doc.selectedLayerIndex = 0
    guard let lower = doc.selectedLayer else { fatalError("no layer") }
    lower.context.setFillColor(NSColor.red.cgColor)
    lower.context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))

    let settings = ToolSettings()
    settings.tool = .moveSelectedPixels
    let engine = ToolEngine(doc: doc, settings: settings)
    doc.selectionPath = CGPath(rect: CGRect(x: 4, y: 4, width: 8, height: 8), transform: nil)

    engine.mouseDown(at: CGPoint(x: 8, y: 8), rightButton: false, modifiers: [])
    engine.mouseUp(at: CGPoint(x: 8, y: 8), modifiers: [])
    check(engine.hasFloatingPixels, "the pixels lift off the lower layer")

    // Move the selection to the upper layer behind the engine's back.
    doc.selectedLayerIndex = 1
    check(engine.commitFloatingPixels(), "the pixels drop")
    check((PixelOps.sample(doc.layers[0], x: 8, y: 8)?.r ?? 0) > 200,
          "back onto the layer they were cut from")
    equal(PixelOps.sample(doc.layers[1], x: 8, y: 8)?.a ?? 99, 0,
          "leaving the layer selected since then empty")
}

windowSection("switching layers leaves lifted pixels where they came from") {
    // Move Selected Pixels lifts the pixels off the layer, so picking another
    // row must put them back down first. Handing them to the newly selected
    // layer would move the image, not just the selection outline.
    let doc = Document(width: 40, height: 40, background: nil)
    guard let lower = doc.selectedLayer else { fatalError("no layer") }
    lower.context.setFillColor(NSColor.red.cgColor)
    lower.context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
    doc.addLayer(named: "Upper")
    doc.selectedLayerIndex = 0

    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)
    controller.settings.tool = .moveSelectedPixels
    let box = CGRect(x: 10, y: 10, width: 20, height: 20)
    doc.selectionPath = CGPath(rect: box, transform: nil)

    // Click to lift, then drag the pixels somewhere new.
    controller.engine.mouseDown(at: CGPoint(x: 20, y: 20), rightButton: false, modifiers: [])
    check(controller.engine.hasFloatingPixels, "the pixels are floating")
    controller.engine.mouseDragged(to: CGPoint(x: 25, y: 25), modifiers: [])
    controller.engine.mouseUp(at: CGPoint(x: 25, y: 25), modifiers: [])

    // Pick the upper layer. The float lands on the layer it was lifted from.
    hub.layersPanel.selectRow(0)
    equal(doc.selectedLayerIndex, 1, "the palette switched layers")
    check(!controller.engine.hasFloatingPixels, "and the float was put down first")

    check((PixelOps.sample(doc.layers[0], x: 25, y: 25)?.a ?? 0) > 200,
          "the moved pixels stayed on their own layer")
    equal(PixelOps.sample(doc.layers[1], x: 25, y: 25)?.a ?? 99, 0,
          "and none of them landed on the layer just picked")
    controller.window?.close()
}

// MARK: - Resampling kernels

section("box average sees every source pixel")
do {
    // A 4x4 split down the middle, black on the left, white on the right.
    let doc = Document(width: 4, height: 4)
    let layer = doc.layers[0]
    layer.context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    layer.context.fill(CGRect(x: 0, y: 0, width: 2, height: 4))
    layer.context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    layer.context.fill(CGRect(x: 2, y: 0, width: 2, height: 4))
    layer.markEdited()

    guard let img = doc.composite() else { check(false, "the 4x4 composited"); exit(1) }
    let halved = Resampler.scaled(img, to: CGSize(width: 2, height: 2), using: .boxAverage)
    check(halved != nil, "box average produced an image")
    if let halved {
        equal(halved.width, 2, "at the width asked for")
        equal(halved.height, 2, "and the height")
        let probe = Layer(width: 2, height: 2, name: "probe")
        probe.draw(image: halved)
        // Each destination pixel covers two source pixels of one colour, so
        // the halves stay pure rather than blurring into each other.
        equal(PixelOps.sample(probe, x: 0, y: 0)?.r ?? 99, 0, "the black half stayed black")
        equal(PixelOps.sample(probe, x: 1, y: 0)?.r ?? 0, 255, "and the white half white")
    }

    // A quarter-size reduction straddles the divide, so the middle averages.
    let quarter = Resampler.scaled(img, to: CGSize(width: 1, height: 1), using: .boxAverage)
    if let quarter {
        let probe = Layer(width: 1, height: 1, name: "probe")
        probe.draw(image: quarter)
        let grey = Int(PixelOps.sample(probe, x: 0, y: 0)?.r ?? 0)
        check(grey > 100 && grey < 155, "half black and half white average to grey — got \(grey)")
    } else {
        check(false, "the 1x1 reduction produced an image")
    }

    // Enlarging has nothing to average, so it hands the draw back.
    check(Resampler.scaled(img, to: CGSize(width: 8, height: 8), using: .boxAverage) == nil,
          "box average declines an enlargement")
}

section("lanczos scales to the size asked for")
do {
    let doc = Document(width: 8, height: 8)
    doc.layers[0].context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    doc.layers[0].context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
    doc.layers[0].markEdited()
    guard let img = doc.composite() else { check(false, "the 8x8 composited"); exit(1) }

    let bigger = Resampler.scaled(img, to: CGSize(width: 20, height: 12), using: .lanczos)
    check(bigger != nil, "lanczos produced an image")
    if let bigger {
        equal(bigger.width, 20, "at the width asked for")
        equal(bigger.height, 12, "and the height, non-proportional included")
    }
    // Same size in, same image out: nothing to resample.
    check(Resampler.scaled(img, to: CGSize(width: 8, height: 8), using: .lanczos)?.width == 8,
          "and an unchanged size is a no-op")
}

section("every kernel resizes a document")
do {
    for kernel in Resampling.allCases {
        let doc = Document(width: 32, height: 32)
        doc.layers[0].context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        doc.layers[0].context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        doc.layers[0].markEdited()
        doc.resizeImage(to: CGSize(width: 16, height: 16), resampling: kernel)
        equal(doc.width, 16, "\(kernel.rawValue) resized the width")
        equal(doc.height, 16, "\(kernel.rawValue) resized the height")
        check((pixel(doc, 8, 4)?.b ?? 0) > 128, "\(kernel.rawValue) kept the filled half")
        // The draw must not leave its kernel behind on the layer's context.
        equal(doc.layers[0].context.interpolationQuality, .high,
              "\(kernel.rawValue) restored the context's own setting")
    }
}

// MARK: - Targeting a file size

/// A gradient with noise in it: something a JPEG encoder cannot flatten to
/// nothing, so the search has a real size curve to bisect.
func busyImage(width: Int = 256, height: Int = 256) -> CGImage {
    let doc = Document(width: width, height: height)
    let ctx = doc.layers[0].context
    var seed: UInt64 = 0x9E3779B97F4A7C15
    for y in stride(from: 0, to: height, by: 2) {
        for x in stride(from: 0, to: width, by: 2) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n = CGFloat((seed >> 33) % 256) / 255
            ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: n,
                                     blue: CGFloat(y) / CGFloat(height), alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }
    }
    doc.layers[0].markEdited()
    return doc.composite()!
}

section("the size dial only ever grows the file")
do {
    let image = busyImage(width: 128, height: 128)
    for method in FileSizeExport.Method.allCases {
        var last = 0
        var grew = true
        for step in 0...8 {
            let dial = FileSizeExport.settings(at: Double(step) / 8, image: image,
                                               format: .jpeg, method: method,
                                               allowsEnlarging: false)
            guard let scaled = FileSizeExport.render(image, to: dial.size, using: .smooth),
                  let data = FileSizeExport.encode(scaled, format: .jpeg, quality: dial.quality) else {
                check(false, "\(method.rawValue) encoded at step \(step)")
                break
            }
            // Bisection is only valid while the curve climbs, so this is the
            // property the whole search rests on.
            if data.count < last { grew = false }
            last = data.count
        }
        check(grew, "\(method.rawValue) grows monotonically along the dial")
    }
    // Nothing is enlarged unless it was asked for.
    let top = FileSizeExport.settings(at: 1, image: image, format: .jpeg,
                                      method: .qualityThenDimensions, allowsEnlarging: false)
    equal(Int(top.size.width), 128, "the dial stops at the original width")
}

section("a jpeg is fitted into a range")
do {
    let image = busyImage()
    let range = FileSizeExport.Range(minKB: 8, maxKB: 16)
    guard let fit = FileSizeExport.fit(image, format: .jpeg, range: range,
                                       method: .qualityThenDimensions) else {
        check(false, "the search returned a result"); exit(1)
    }
    check(fit.isInRange, "the fit landed in the range — got \(fit.byteCount) bytes")
    check(fit.byteCount <= range.maxBytes, "and never above the ceiling")
    check(fit.byteCount >= range.minBytes, "nor below the floor")
    check(fit.quality != nil, "a lossy format reports the quality it used")
    check(fit.attempts > 1, "the search actually searched")
    check(!fit.data.isEmpty, "and produced bytes to write")
}

section("an impossible ceiling reports the closest miss")
do {
    let image = busyImage()
    // Far below what 256x256 of noise can be squeezed into.
    let fit = FileSizeExport.fit(image, format: .jpeg,
                                 range: FileSizeExport.Range(minBytes: 0, maxBytes: 64),
                                 method: .quality)
    check(fit != nil, "the search still returned something")
    if let fit {
        check(!fit.isInRange, "and admits it missed")
        check(!fit.missedLow, "in the direction of being too big")
        check(!fit.data.isEmpty, "with the nearest encoding to offer anyway")
    }
}

section("an impossible floor is reported as too small")
do {
    let image = busyImage(width: 64, height: 64)
    let fit = FileSizeExport.fit(image, format: .jpeg,
                                 range: FileSizeExport.Range(minKB: 4096, maxKB: 8192),
                                 method: .quality)
    check(fit?.isInRange == false, "the floor was out of reach")
    check(fit?.missedLow == true, "and the miss is marked as low")
}

section("a lossless format is fitted by dimensions alone")
do {
    let image = busyImage()
    // A ceiling well under what the full-size PNG weighs, so the only way to
    // meet it is to shed pixels.
    guard let fit = FileSizeExport.fit(image, format: .png,
                                       range: FileSizeExport.Range(minKB: 0, maxKB: 12),
                                       method: .quality, resampling: .boxAverage) else {
        check(false, "the png search returned a result"); exit(1)
    }
    check(fit.quality == nil, "png reports no quality")
    check(fit.byteCount <= 12 * 1024, "and still respects the ceiling")
    check(Int(fit.pixelSize.width) < 256, "the only dial it had was the pixel count")
}

section("enlarging is opt-in")
do {
    let image = busyImage(width: 64, height: 64)
    let small = FileSizeExport.settings(at: 1, image: image, format: .png,
                                        method: .dimensions, allowsEnlarging: false)
    equal(Int(small.size.width), 64, "off, the search stops at the original size")
    let big = FileSizeExport.settings(at: 1, image: image, format: .png,
                                      method: .dimensions, allowsEnlarging: true)
    check(Int(big.size.width) > 64, "on, it may go past it to reach a floor")
}

windowSection("an oversized paste asks before it clips") {
    // A clip wider and taller than the canvas it is going onto.
    let source = Document(width: 40, height: 30, background: .red)
    let sourceHub = PaletteHub()
    let sourceController = MainWindowController(doc: source, hub: sourceHub)
    sourceController.selectAll(nil)
    sourceController.copy(nil)

    func target() -> (Document, MainWindowController) {
        let doc = Document(width: 20, height: 20, background: .white)
        return (doc, MainWindowController(doc: doc, hub: PaletteHub()))
    }

    // Expanding grows the canvas to hold every pasted pixel.
    let (grown, expandController) = target()
    expandController.oversizePastePolicy = .expand
    expandController.paste(nil)
    expandController.commitPendingEdits()
    equal(grown.width, 40, "the canvas grew to the pasted width")
    equal(grown.height, 30, "and to its height")
    check((pixel(grown, 5, 5)?.r ?? 0) > 200, "with the paste landed in it")
    expandController.window?.close()

    // Keeping the canvas leaves the paste floating at full size instead.
    let (kept, keepController) = target()
    keepController.oversizePastePolicy = .keep
    keepController.paste(nil)
    equal(kept.width, 20, "keeping the canvas left the width alone")
    check(keepController.engine.hasFloatingPixels, "and the paste is floating over it")
    equal(keepController.engine.floatingRect.width, 40, "at its own full width")
    check(keepController.engine.commitFloatingPixels(), "which lands when committed")
    keepController.window?.close()

    // Cancelling does nothing at all.
    let (untouched, cancelController) = target()
    cancelController.oversizePastePolicy = .cancel
    let steps = untouched.history.entries.count
    cancelController.paste(nil)
    equal(untouched.history.entries.count, steps, "cancelling left the history alone")
    check(!cancelController.engine.hasFloatingPixels, "and nothing floating")
    equal(untouched.width, 20, "and the canvas as it was")
    cancelController.window?.close()

    // A paste that fits is never asked about: the scaled pastes are about the
    // canvas already, and a small clip has nothing to lose.
    let (fitted, fitController) = target()
    fitController.oversizePastePolicy = .cancel
    fitController.pasteFitToCanvas(nil)
    fitController.commitPendingEdits()
    check(fitted.history.entries.count > 1, "a fit-to-canvas paste went straight through")
    fitController.window?.close()

    sourceController.window?.close()
}

windowSection("the canvas holds keyboard focus from launch") {
    let doc = Document(width: 40, height: 40, background: .white)
    let hub = PaletteHub()
    let controller = MainWindowController(doc: doc, hub: hub)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)

    // A text field in the options bar used to be first responder here, which
    // meant the field editor took ⌘V and the first paste of a session went
    // into the brush-size box.
    var chain: [NSResponder] = []
    var responder: NSResponder? = controller.window?.firstResponder
    while let current = responder {
        chain.append(current)
        responder = current.nextResponder
    }
    check(chain.first is CanvasView, "the canvas is first responder — got \(chain.map { type(of: $0) })")
    check(!chain.contains { $0 is NSTextView }, "no field editor sits in front of it")
    check(chain.contains { $0.responds(to: #selector(MainWindowController.paste(_:))) },
          "and the chain reaches something that pastes")

    // Switching tools rebuilds the options bar, which must not take it back.
    controller.selectTool(.paintbrush)
    controller.selectTool(.text)
    controller.selectTool(.paintbrush)
    check(controller.window?.firstResponder is CanvasView, "a tool change leaves focus on the canvas")
    controller.window?.close()
}

print(failures == 0
      ? "\nAll \(checks) checks passed."
      : "\n\(failures) of \(checks) checks failed.")
exit(failures == 0 ? 0 : 1)
