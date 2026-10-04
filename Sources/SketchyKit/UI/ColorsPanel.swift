import AppKit

/// Primary/secondary swatches, an HSV wheel, and the recent-color palette.
final class ColorsPanel: FloatingPanel {
    let palette = ColorsPaletteView(frame: .zero)

    private var primarySwatch: SwatchView { palette.primarySwatch }
    private var secondarySwatch: SwatchView { palette.secondarySwatch }
    private var wheel: ColorWheelView { palette.wheel }
    private var valueSlider: NSSlider { palette.valueSlider }
    private var paletteView: PaletteView { palette.paletteView }

    var primary: NSColor = .black { didSet { primarySwatch.color = primary; syncWheel(); onColorsChanged?(primary, secondary) } }
    var secondary: NSColor = .white { didSet { secondarySwatch.color = secondary; onColorsChanged?(primary, secondary) } }
    var editingSecondary = false
    /// Set while the fields are being refreshed, so echoing back does not fight
    /// whatever the user is typing.
    private var isSyncingFields = false

    var onColorsChanged: ((NSColor, NSColor) -> Void)?

    init() {
        let width: CGFloat = 232
        let height = ColorsPaletteView(frame: .zero).preferredHeight(forWidth: width) ?? 380
        super.init(title: "Colors", size: NSSize(width: width, height: height))
        styleMask.insert(.resizable)
        contentMinSize = NSSize(width: 96, height: 200)

        palette.frame = NSRect(x: 0, y: 0, width: width, height: height)
        palette.autoresizingMask = [.width, .height]

        primarySwatch.color = primary
        secondarySwatch.color = secondary
        primarySwatch.onClick = { [weak self] in self?.editColor(secondary: false) }
        secondarySwatch.onClick = { [weak self] in self?.editColor(secondary: true) }

        palette.swapButton.target = self
        palette.swapButton.action = #selector(swapColors)
        palette.resetButton.target = self
        palette.resetButton.action = #selector(resetColors)
        palette.moreButton.target = self
        palette.moreButton.action = #selector(showSystemPicker)
        palette.addSwatchButton.target = self
        palette.addSwatchButton.action = #selector(addCurrentToPalette)
        valueSlider.target = self
        valueSlider.action = #selector(valueChanged)
        wheel.onPick = { [weak self] c in
            guard let self else { return }
            applyPicked(c)
            // Picking off a black wheel lifts the value, so the slider and the
            // fields have to follow it up.
            valueSlider.doubleValue = Double(wheel.brightness)
            syncFields()
        }

        for name in PaletteView.presets.keys.sorted() {
            let item = NSMenuItem(title: name, action: #selector(choosePalette(_:)), keyEquivalent: "")
            item.target = self
            palette.presetsButton.menu?.addItem(item)
        }

        palette.hexField.target = self
        palette.hexField.action = #selector(hexEdited)
        for field in palette.rgbaFields {
            field.target = self
            field.action = #selector(rgbaEdited)
        }
        for field in palette.hsvFields {
            field.target = self
            field.action = #selector(hsvEdited)
        }

        paletteView.onPick = { [weak self] c, secondary in
            guard let self else { return }
            if secondary { self.secondary = c } else { self.primary = c }
        }

        contentView = palette
        syncWheel()
    }

    /// Pushes the active color into every numeric field.
    private func syncFields() {
        isSyncingFields = true
        defer { isSyncingFields = false }

        let color = editingSecondary ? secondary : primary
        palette.hexField.stringValue = color.hexString

        let bytes = color.rgbaBytes
        palette.redField.integerValue = bytes.r
        palette.greenField.integerValue = bytes.g
        palette.blueField.integerValue = bytes.b
        palette.alphaField.integerValue = bytes.a

        let hsv = color.hsvValues
        palette.hueField.integerValue = hsv.h
        palette.saturationField.integerValue = hsv.s
        palette.valueField.integerValue = hsv.v
    }

    @objc private func hexEdited() {
        guard !isSyncingFields else { return }
        guard let color = NSColor.fromHex(palette.hexField.stringValue) else {
            syncFields()   // reject anything unparseable and put the old value back
            return
        }
        applyPicked(color)
        syncWheel()
    }

    @objc private func rgbaEdited() {
        guard !isSyncingFields else { return }
        applyPicked(NSColor.fromBytes(r: palette.redField.integerValue,
                                      g: palette.greenField.integerValue,
                                      b: palette.blueField.integerValue,
                                      a: palette.alphaField.integerValue))
        syncWheel()
    }

    @objc private func hsvEdited() {
        guard !isSyncingFields else { return }
        let alpha = CGFloat(palette.alphaField.integerValue) / 255
        applyPicked(NSColor.fromHSV(h: palette.hueField.integerValue,
                                    s: palette.saturationField.integerValue,
                                    v: palette.valueField.integerValue,
                                    alpha: alpha))
        syncWheel()
    }

    private func syncWheel() {
        let c = (editingSecondary ? secondary : primary).usingColorSpace(.deviceRGB) ?? .black
        wheel.brightness = c.brightnessComponent
        valueSlider.doubleValue = Double(c.brightnessComponent)
        wheel.selection = c
        syncFields()
    }

    private func applyPicked(_ c: NSColor) {
        if editingSecondary { secondary = c } else { primary = c }
    }

    func setColor(_ c: NSColor, secondary isSecondary: Bool) {
        if isSecondary { secondary = c } else { primary = c }
        paletteView.addRecent(c)
        syncWheel()
    }

    @objc private func valueChanged() {
        wheel.brightness = CGFloat(valueSlider.doubleValue)
        let base = (editingSecondary ? secondary : primary).usingColorSpace(.deviceRGB) ?? .black
        applyPicked(NSColor(calibratedHue: base.hueComponent,
                            saturation: base.saturationComponent,
                            brightness: CGFloat(valueSlider.doubleValue), alpha: base.alphaComponent))
    }

    @objc private func swapColors() {
        let p = primary
        primary = secondary
        secondary = p
        syncWheel()
    }

    @objc private func resetColors() {
        primary = .black
        secondary = .white
        syncWheel()
    }

    private func editColor(secondary isSecondary: Bool) {
        editingSecondary = isSecondary
        primarySwatch.isActive = !isSecondary
        secondarySwatch.isActive = isSecondary
        syncWheel()
    }

    @objc private func showSystemPicker() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = editingSecondary ? secondary : primary
        panel.setTarget(self)
        panel.setAction(#selector(systemColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func systemColorChanged(_ sender: NSColorPanel) {
        applyPicked(sender.color)
        syncWheel()
    }

    @objc private func addCurrentToPalette() {
        paletteView.addRecent(primary)
    }

    @objc private func choosePalette(_ sender: NSMenuItem) {
        paletteView.load(preset: sender.title)
    }
}

/// A single color chip with a checkerboard behind it for transparency.
final class SwatchView: NSView {
    var color: NSColor = .black { didSet { needsDisplay = true } }
    var isActive: Bool = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        drawCheckerboard(in: bounds, cell: 4)
        color.setFill()
        bounds.fill(using: .sourceOver)
        (isActive ? NSColor.controlAccentColor : NSColor(white: 0.35, alpha: 1)).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        p.lineWidth = isActive ? 2 : 1
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The two-row palette strip at the bottom of the Colors panel.
final class PaletteView: NSView {
    static let presets: [String: [NSColor]] = [
        "Default": PaletteView.defaultColors,
        "Grayscale": (0..<32).map { NSColor(white: CGFloat($0) / 31, alpha: 1) },
        "Pastel": (0..<32).map { NSColor(calibratedHue: CGFloat($0) / 32, saturation: 0.35, brightness: 1, alpha: 1) },
        "Vivid": (0..<32).map { NSColor(calibratedHue: CGFloat($0) / 32, saturation: 1, brightness: 1, alpha: 1) }
    ]

    static let defaultColors: [NSColor] = {
        var colors: [NSColor] = [.black, NSColor(white: 0.25, alpha: 1), NSColor(white: 0.5, alpha: 1),
                                 NSColor(white: 0.75, alpha: 1), .white]
        for i in 0..<27 {
            colors.append(NSColor(calibratedHue: CGFloat(i) / 27, saturation: 1, brightness: 1, alpha: 1))
        }
        var second: [NSColor] = []
        for i in 0..<32 {
            second.append(NSColor(calibratedHue: CGFloat(i) / 32, saturation: 0.55, brightness: 0.75, alpha: 1))
        }
        return colors + second
    }()

    private var colors: [NSColor] = PaletteView.defaultColors
    var onPick: ((NSColor, Bool) -> Void)?

    private let columns = 16
    private var cellSize: NSSize {
        NSSize(width: bounds.width / CGFloat(columns), height: bounds.height / CGFloat(rows))
    }
    private var rows: Int { max(1, Int(ceil(Double(colors.count) / Double(columns)))) }

    override var isFlipped: Bool { true }

    func load(preset: String) {
        colors = PaletteView.presets[preset] ?? PaletteView.defaultColors
        needsDisplay = true
    }

    func addRecent(_ c: NSColor) {
        colors.insert(c, at: 0)
        if colors.count > columns * 4 { colors.removeLast() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let cs = cellSize
        for (i, c) in colors.enumerated() {
            let r = NSRect(x: CGFloat(i % columns) * cs.width,
                           y: CGFloat(i / columns) * cs.height,
                           width: cs.width, height: cs.height)
            c.setFill()
            r.insetBy(dx: 0.5, dy: 0.5).fill()
            NSColor(white: 0.2, alpha: 1).setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { pick(event, secondary: false) }
    override func rightMouseDown(with event: NSEvent) { pick(event, secondary: true) }

    private func pick(_ event: NSEvent, secondary: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        let cs = cellSize
        let index = Int(p.y / cs.height) * columns + Int(p.x / cs.width)
        guard colors.indices.contains(index) else { return }
        onPick?(colors[index], secondary)
    }
}
