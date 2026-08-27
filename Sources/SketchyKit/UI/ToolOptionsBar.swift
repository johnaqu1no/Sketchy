import AppKit

/// The context-sensitive strip under the window toolbar. Rebuilt whenever the
/// active tool changes so it only shows options that tool actually uses.
final class ToolOptionsBar: NSView {
    private let settings: ToolSettings
    private var stack = NSStackView()
    var onChange: (() -> Void)?
    var onToolChange: ((ToolID) -> Void)?

    init(settings: ToolSettings) {
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 34))
        wantsLayer = true
        clipsToBounds = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 0.5))
        p.line(to: NSPoint(x: bounds.width, y: 0.5))
        p.stroke()
    }

    // MARK: - Building blocks

    private func label(_ s: String) -> NSTextField {
        let tf = NSTextField(labelWithString: s)
        tf.font = .systemFont(ofSize: 12)
        tf.textColor = .secondaryLabelColor
        return tf
    }

    private func popup(_ titles: [String], selected: String, width: CGFloat, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 22), pullsDown: false)
        p.addItems(withTitles: titles)
        p.selectItem(withTitle: selected)
        p.controlSize = .small
        p.font = .systemFont(ofSize: 12)
        p.target = self
        p.action = action
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        return p
    }

    func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        stack.addArrangedSubview(label("Tool:"))
        let toolPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for t in ToolID.paletteOrder {
            let item = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            item.representedObject = t.rawValue
            toolPopup.menu?.addItem(item)
        }
        toolPopup.selectItem(withTitle: settings.tool.title)
        toolPopup.controlSize = .small
        toolPopup.font = .systemFont(ofSize: 12)
        toolPopup.target = self
        toolPopup.action = #selector(toolPicked(_:))
        toolPopup.widthAnchor.constraint(equalToConstant: 168).isActive = true
        stack.addArrangedSubview(toolPopup)

        switch settings.tool {
        case .shapes:
            let shapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
            for s in ShapeKind.allCases {
                let item = NSMenuItem(title: s.rawValue, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.rawValue)
                shapePopup.menu?.addItem(item)
            }
            shapePopup.selectItem(withTitle: settings.shape.rawValue)
            shapePopup.controlSize = .small
            shapePopup.target = self
            shapePopup.action = #selector(shapePicked(_:))
            shapePopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
            stack.addArrangedSubview(shapePopup)
            addDrawMode()
            addSizeControl()
            addStrokeStyle()
            addFillStyle()
            addBlend()
        case .line:
            addSizeControl()
            addStrokeStyle()
            addBlend()
        case .paintbrush:
            addSizeControl()
            addSlider(title: "Hardness", value: settings.hardness, action: #selector(hardnessChanged(_:)))
            addBlend()
        case .pencil:
            addBlend()
        case .eraser:
            addSizeControl()
        case .paintBucket, .magicWand:
            addSlider(title: "Tolerance", value: settings.tolerance, action: #selector(toleranceChanged(_:)))
            let scope = popup(["Contiguous", "Global"],
                              selected: settings.fillGlobally ? "Global" : "Contiguous",
                              width: 120, action: #selector(fillScopeChanged(_:)))
            stack.addArrangedSubview(label("Flood Mode:"))
            stack.addArrangedSubview(scope)
            if settings.tool == .paintBucket { addBlend() } else { addSelectionMode() }
        case .rectangleSelect, .ellipseSelect, .lassoSelect:
            addSelectionMode()
        case .gradient:
            let kinds = popup(GradientKind.allCases.map(\.rawValue), selected: settings.gradientKind.rawValue,
                              width: 130, action: #selector(gradientChanged(_:)))
            stack.addArrangedSubview(label("Gradient:"))
            stack.addArrangedSubview(kinds)
            addSlider(title: "Strength", value: settings.gradientStrength,
                      action: #selector(strengthChanged(_:)))
            addBlend()
        case .text:
            let fonts = NSFontManager.shared.availableFontFamilies
            let fontPopup = popup(fonts, selected: fonts.contains(settings.fontName) ? settings.fontName : fonts[0],
                                  width: 180, action: #selector(fontChanged(_:)))
            stack.addArrangedSubview(label("Font:"))
            stack.addArrangedSubview(fontPopup)
            let sizeField = NSTextField(string: String(Int(settings.fontSize)))
            sizeField.widthAnchor.constraint(equalToConstant: 46).isActive = true
            sizeField.controlSize = .small
            sizeField.target = self
            sizeField.action = #selector(fontSizeChanged(_:))
            stack.addArrangedSubview(sizeField)
            let styleSeg = NSSegmentedControl(labels: ["B", "I", "U"], trackingMode: .selectAny,
                                              target: self, action: #selector(fontStyleChanged(_:)))
            styleSeg.setSelected(settings.bold, forSegment: 0)
            styleSeg.setSelected(settings.italic, forSegment: 1)
            styleSeg.setSelected(settings.underline, forSegment: 2)
            stack.addArrangedSubview(styleSeg)
            addBlend()
        case .cloneStamp, .recolor:
            addSizeControl()
            if settings.tool == .recolor {
                addSlider(title: "Tolerance", value: settings.tolerance, action: #selector(toleranceChanged(_:)))
                stack.addArrangedSubview(label("Replace:"))
                stack.addArrangedSubview(popup(RecolorTarget.allCases.map(\.rawValue),
                                               selected: settings.recolorTarget.rawValue,
                                               width: 150, action: #selector(recolorTargetChanged(_:))))
                // Sampling only matters when the target comes off the canvas.
                if settings.recolorTarget == .sampledColor {
                    stack.addArrangedSubview(label("Sampling:"))
                    stack.addArrangedSubview(popup(["Layer", "Image"],
                                                   selected: settings.sampleMerged ? "Image" : "Layer",
                                                   width: 100, action: #selector(samplingChanged(_:))))
                }
            }
        case .healingBrush, .spotHealing:
            addSizeControl()
            addSlider(title: "Hardness", value: settings.hardness, action: #selector(hardnessChanged(_:)))
        case .smudge, .blurBrush, .sharpenBrush:
            addSizeControl()
            addSlider(title: "Strength", value: settings.brushStrength,
                      action: #selector(brushStrengthChanged(_:)))
            addSlider(title: "Hardness", value: settings.hardness, action: #selector(hardnessChanged(_:)))
        case .moveSelectedPixels:
            stack.addArrangedSubview(label("Scaling:"))
            stack.addArrangedSubview(popup(Resampling.allCases.map(\.rawValue),
                                           selected: settings.resampling.rawValue,
                                           width: 130, action: #selector(resamplingChanged(_:))))
        case .colorPicker:
            let sampling = popup(["Layer", "Image"], selected: settings.sampleMerged ? "Image" : "Layer",
                                 width: 100, action: #selector(samplingChanged(_:)))
            stack.addArrangedSubview(label("Sampling:"))
            stack.addArrangedSubview(sampling)
        default:
            break
        }

        if settings.tool != .pencil && settings.tool != .zoom && settings.tool != .pan {
            let aa = NSButton(checkboxWithTitle: "Antialiasing", target: self, action: #selector(aaChanged(_:)))
            aa.state = settings.antialiasing ? .on : .off
            aa.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(aa)
        }

        needsDisplay = true
    }

    private func addDrawMode() {
        stack.addArrangedSubview(label("Draw Mode"))
        let seg = NSSegmentedControl(images: DrawMode.allCases.map {
            NSImage.symbol($0.symbol, $0.title)
        }, trackingMode: .selectOne, target: self, action: #selector(drawModeChanged(_:)))
        seg.selectedSegment = settings.drawMode.rawValue
        for (i, m) in DrawMode.allCases.enumerated() { seg.setToolTip(m.title, forSegment: i) }
        stack.addArrangedSubview(seg)
    }

    private func addSizeControl() {
        stack.addArrangedSubview(label("Size:"))
        let slider = NSSlider(value: Double(settings.brushWidth), minValue: 1, maxValue: 200,
                              target: self, action: #selector(sizeChanged(_:)))
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        slider.tag = 900
        stack.addArrangedSubview(slider)
        let stepper = NSTextField(string: String(Int(settings.brushWidth)))
        stepper.widthAnchor.constraint(equalToConstant: 42).isActive = true
        stepper.controlSize = .small
        stepper.target = self
        stepper.action = #selector(sizeFieldChanged(_:))
        stepper.tag = 901
        stack.addArrangedSubview(stepper)
    }

    private func addSlider(title: String, value: CGFloat, action: Selector) {
        stack.addArrangedSubview(label("\(title):"))
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: self, action: action)
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        stack.addArrangedSubview(slider)
    }

    private func addStrokeStyle() {
        stack.addArrangedSubview(label("Style:"))
        stack.addArrangedSubview(popup(StrokeStyle.allCases.map(\.rawValue),
                                       selected: settings.strokeStyle.rawValue,
                                       width: 130, action: #selector(strokeChanged(_:))))
    }

    private func addFillStyle() {
        stack.addArrangedSubview(label("Fill:"))
        stack.addArrangedSubview(popup(FillStyle.allCases.map(\.rawValue),
                                       selected: settings.fillStyle.rawValue,
                                       width: 150, action: #selector(fillChanged(_:))))
    }

    private func addBlend() {
        stack.addArrangedSubview(popup(LayerBlendMode.allCases.map(\.rawValue),
                                       selected: settings.blendMode.rawValue,
                                       width: 118, action: #selector(blendChanged(_:))))
    }

    private func addSelectionMode() {
        stack.addArrangedSubview(label("Mode:"))
        stack.addArrangedSubview(popup(SelectionMode.allCases.map(\.rawValue),
                                       selected: settings.selectionMode.rawValue,
                                       width: 130, action: #selector(selectionModeChanged(_:))))
    }

    // MARK: - Actions

    @objc private func toolPicked(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let tool = ToolID(rawValue: raw) else { return }
        settings.tool = tool
        onToolChange?(tool)
        rebuild()
    }

    @objc private func shapePicked(_ sender: NSPopUpButton) {
        settings.shape = ShapeKind(rawValue: sender.titleOfSelectedItem ?? "") ?? .rectangle
        onChange?()
    }

    @objc private func drawModeChanged(_ sender: NSSegmentedControl) {
        settings.drawMode = DrawMode(rawValue: sender.selectedSegment) ?? .outlineAndFill
        onChange?()
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        settings.brushWidth = CGFloat(sender.doubleValue.rounded())
        if let field = stack.arrangedSubviews.first(where: { $0.tag == 901 }) as? NSTextField {
            field.stringValue = String(Int(settings.brushWidth))
        }
        onChange?()
    }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        let v = max(1, min(200, CGFloat(sender.doubleValue)))
        settings.brushWidth = v
        sender.stringValue = String(Int(v))
        if let slider = stack.arrangedSubviews.first(where: { $0.tag == 900 }) as? NSSlider {
            slider.doubleValue = Double(v)
        }
        onChange?()
    }

    @objc private func hardnessChanged(_ sender: NSSlider) { settings.hardness = CGFloat(sender.doubleValue); onChange?() }
    @objc private func brushStrengthChanged(_ sender: NSSlider) {
        settings.brushStrength = CGFloat(sender.doubleValue); onChange?()
    }
    @objc private func strengthChanged(_ sender: NSSlider) {
        settings.gradientStrength = CGFloat(sender.doubleValue); onChange?()
    }
    @objc private func toleranceChanged(_ sender: NSSlider) { settings.tolerance = CGFloat(sender.doubleValue); onChange?() }
    @objc private func strokeChanged(_ sender: NSPopUpButton) {
        settings.strokeStyle = StrokeStyle(rawValue: sender.titleOfSelectedItem ?? "") ?? .solid; onChange?()
    }
    @objc private func fillChanged(_ sender: NSPopUpButton) {
        settings.fillStyle = FillStyle(rawValue: sender.titleOfSelectedItem ?? "") ?? .solidColor; onChange?()
    }
    @objc private func blendChanged(_ sender: NSPopUpButton) {
        settings.blendMode = LayerBlendMode(rawValue: sender.titleOfSelectedItem ?? "") ?? .normal; onChange?()
    }
    @objc private func selectionModeChanged(_ sender: NSPopUpButton) {
        settings.selectionMode = SelectionMode(rawValue: sender.titleOfSelectedItem ?? "") ?? .replace; onChange?()
    }
    @objc private func gradientChanged(_ sender: NSPopUpButton) {
        settings.gradientKind = GradientKind(rawValue: sender.titleOfSelectedItem ?? "") ?? .linear; onChange?()
    }
    @objc private func fillScopeChanged(_ sender: NSPopUpButton) {
        settings.fillGlobally = (sender.titleOfSelectedItem == "Global"); onChange?()
    }
    @objc private func samplingChanged(_ sender: NSPopUpButton) {
        settings.sampleMerged = (sender.titleOfSelectedItem == "Image"); onChange?()
    }
    @objc private func recolorTargetChanged(_ sender: NSPopUpButton) {
        settings.recolorTarget = RecolorTarget(rawValue: sender.titleOfSelectedItem ?? "") ?? .secondaryColor
        // The sampling popup appears and disappears with the mode.
        rebuild()
        onChange?()
    }
    @objc private func resamplingChanged(_ sender: NSPopUpButton) {
        settings.resampling = Resampling(rawValue: sender.titleOfSelectedItem ?? "") ?? .pixels
        onChange?()
    }

    @objc private func aaChanged(_ sender: NSButton) { settings.antialiasing = (sender.state == .on); onChange?() }
    @objc private func fontChanged(_ sender: NSPopUpButton) { settings.fontName = sender.titleOfSelectedItem ?? "Helvetica"; onChange?() }
    @objc private func fontSizeChanged(_ sender: NSTextField) {
        settings.fontSize = max(4, min(400, CGFloat(sender.doubleValue))); onChange?()
    }
    @objc private func fontStyleChanged(_ sender: NSSegmentedControl) {
        settings.bold = sender.isSelected(forSegment: 0)
        settings.italic = sender.isSelected(forSegment: 1)
        settings.underline = sender.isSelected(forSegment: 2)
        onChange?()
    }
}
