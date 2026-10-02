import AppKit

/// Bottom strip: tool hints on the left, size / cursor / zoom on the right.
final class StatusBar: NSView {
    private let hintField = NSTextField(labelWithString: "")
    private let measurementField = NSTextField(labelWithString: "")
    private let cursorField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    let zoomSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let zoomField = NSTextField(labelWithString: "100%")

    var onZoomSlider: ((CGFloat) -> Void)?
    private var flashToken = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 24))
        wantsLayer = true
        clipsToBounds = true

        for tf in [hintField, measurementField, cursorField, sizeField, zoomField] {
            tf.font = .systemFont(ofSize: 11)
            tf.textColor = .secondaryLabelColor
            addSubview(tf)
        }
        hintField.frame = NSRect(x: 10, y: 4, width: 560, height: 16)
        hintField.autoresizingMask = [.width]

        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomChanged)
        addSubview(zoomSlider)

        layoutRight()
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutRight()
    }

    private func layoutRight() {
        let w = bounds.width
        measurementField.frame = NSRect(x: w - 680, y: 4, width: 150, height: 16)
        measurementField.alignment = .right
        cursorField.frame = NSRect(x: w - 520, y: 4, width: 120, height: 16)
        cursorField.alignment = .right
        sizeField.frame = NSRect(x: w - 390, y: 4, width: 120, height: 16)
        sizeField.alignment = .right
        zoomSlider.frame = NSRect(x: w - 250, y: 3, width: 160, height: 18)
        zoomField.frame = NSRect(x: w - 70, y: 4, width: 60, height: 16)
        zoomField.alignment = .right
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        p.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        p.stroke()
    }

    @objc private func zoomChanged() {
        // Slider is logarithmic between 5% and 3200%.
        let t = CGFloat(zoomSlider.doubleValue)
        onZoomSlider?(pow(2, t * (5 + 4.32) - 4.32))
    }

    func setZoom(_ zoom: CGFloat) {
        zoomField.stringValue = "\(Int((zoom * 100).rounded()))%"
        let t = (log2(zoom) + 4.32) / (5 + 4.32)
        zoomSlider.doubleValue = Double(min(1, max(0, t)))
    }

    func setDocumentSize(_ size: CGSize) {
        sizeField.stringValue = "\(Int(size.width)) × \(Int(size.height))"
    }

    /// Size of whatever is being selected or moved, in pixels.
    func setMeasurement(_ rect: CGRect?) {
        guard let rect, rect.width >= 1 || rect.height >= 1 else {
            measurementField.stringValue = ""
            return
        }
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        measurementField.stringValue = "\(width) × \(height) px"
        measurementField.textColor = .labelColor
    }

    func setCursor(_ p: CGPoint?) {
        cursorField.stringValue = p.map { "\(Int($0.x)), \(Int($0.y))" } ?? ""
    }

    /// Shows a one-off message in place of the hint line for a few seconds.
    func flash(_ message: String, thenHintFor tool: ToolID) {
        hintField.attributedStringValue = NSAttributedString(
            string: message,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        flashToken += 1
        let token = flashToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, token == flashToken else { return }
            setHint(for: tool)
        }
    }

    func setHint(for tool: ToolID) {
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.labelColor
        ]
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ]
        let parts: [(String, String)]
        switch tool {
        case .shapes, .line:
            parts = [("Drag", "Place"), ("Corners", "Resize"), ("Inside", "Move"),
                     ("Outside", "Rotate"), ("⏎", "Commit")]
        case .rectangleSelect, .ellipseSelect, .lassoSelect:
            parts = [("Drag", "Select"), ("⌥", "Add"), ("⌘", "Subtract"),
                     ("⇧", "Constrain"), ("⌘D", "Deselect")]
        case .polygonLassoSelect:
            parts = [("Click", "Corner"), ("Click start", "Close"), ("⏎", "Close"),
                     ("⌫", "Undo corner"), ("⎋", "Cancel")]
        case .magicWand:
            parts = [("Click", "Select similar"), ("⌥", "Add"), ("⌘", "Subtract"),
                     ("⌥scroll", "Tolerance")]
        case .paintbrush, .pencil, .eraser:
            parts = [("Drag", "Paint"), ("Right-drag", "Secondary color"),
                     ("[ ]", "Brush size"), ("⌥scroll", "Size")]
        case .paintBucket:
            parts = [("Click", "Fill"), ("Right-click", "Fill with secondary"),
                     ("⌥scroll", "Tolerance")]
        case .colorPicker:
            parts = [("Click", "Pick primary"), ("Right-click", "Pick secondary")]
        case .cloneStamp:
            parts = [("⌥-click", "Set source"), ("Drag", "Clone")]
        case .healingBrush:
            parts = [("⌥-click", "Set source"), ("Drag", "Heal"), ("⌥scroll", "Size")]
        case .spotHealing:
            parts = [("Drag", "Heal over the blemish"), ("⌥scroll", "Size")]
        case .smudge:
            parts = [("Drag", "Pull the color along"), ("⌥scroll", "Size"),
                     ("⌥⇧scroll", "Strength")]
        case .blurBrush, .sharpenBrush:
            parts = [("Drag", tool == .blurBrush ? "Soften" : "Sharpen"),
                     ("⌥scroll", "Size"), ("⌥⇧scroll", "Strength")]
        case .gradient:
            parts = [("Drag", "Place gradient"), ("Right-drag", "Reverse colors"),
                     ("⌥scroll", "Strength")]
        case .text:
            parts = [("Drag", "Size the box"), ("Handles", "Resize"),
                     ("⌘⏎", "Commit"), ("⎋", "Cancel")]
        case .zoom:
            parts = [("Click", "Zoom in"), ("⌥-click", "Zoom out")]
        case .pan:
            parts = [("Drag", "Pan the canvas")]
        case .moveSelection:
            parts = [("Drag", "Move"), ("Handles", "Resize"), ("⇧", "Keep proportions"),
                     ("⌘D", "Deselect")]
        case .moveSelectedPixels:
            parts = [("Drag", "Move"), ("Handles", "Resize"), ("Knob", "Rotate"),
                     ("⇧", "Proportions / 15°"), ("⏎", "Drop"), ("⎋", "Put back")]
        case .recolor:
            parts = [("Drag", "Paint primary over the replaced color"),
                     ("Right-drag", "Reverse"), ("Replace", "What is targeted")]
        }
        let s = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ")) }
            s.append(NSAttributedString(string: part.0 + " ", attributes: bold))
            s.append(NSAttributedString(string: part.1, attributes: plain))
        }
        hintField.attributedStringValue = s
    }
}
