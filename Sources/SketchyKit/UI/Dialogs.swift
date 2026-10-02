import AppKit

/// Small modal sheets: new image, resize, layer properties, single-slider effects.
enum Dialogs {

    /// What the user chose in a resize sheet.
    struct SizeChoice {
        let size: CGSize
        /// Unit coordinates, y up: (0, 1) is the top-left cell of the grid.
        let anchor: CGPoint
        /// True when the sheet's proportions checkbox was left on.
        let keepsProportions: Bool
        let resampling: Resampling
    }

    /// An empty `anchorLabel` hides the grid, for sheets where it means nothing.
    /// `resampling` nil hides the resampling popup, for sheets that never scale.
    static func sizeSheet(title: String,
                          message: String,
                          width: Int,
                          height: Int,
                          anchorLabel: String = "",
                          resampling: Resampling? = nil,
                          in window: NSWindow,
                          completion: @escaping (SizeChoice?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let showsAnchor = !anchorLabel.isEmpty
        let showsResampling = resampling != nil
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: showsAnchor ? 320 : 240,
                                             height: (showsAnchor ? 112 : 84) + (showsResampling ? 30 : 0)))
        let top = container.frame.height - 26
        let widthLabel = NSTextField(labelWithString: "Width:")
        widthLabel.frame = NSRect(x: 0, y: top, width: 60, height: 20)
        let widthField = NSTextField(string: String(width))
        widthField.frame = NSRect(x: 64, y: top - 2, width: 90, height: 22)

        let heightLabel = NSTextField(labelWithString: "Height:")
        heightLabel.frame = NSRect(x: 0, y: top - 28, width: 60, height: 20)
        let heightField = NSTextField(string: String(height))
        heightField.frame = NSRect(x: 64, y: top - 30, width: 90, height: 22)

        let ratio = NSButton(checkboxWithTitle: "Maintain aspect ratio", target: nil, action: nil)
        ratio.frame = NSRect(x: 0, y: top - 58, width: 220, height: 20)
        ratio.state = .on

        let anchorTitle = NSTextField(labelWithString: anchorLabel)
        anchorTitle.frame = NSRect(x: 196, y: top + 2, width: 120, height: 18)
        anchorTitle.font = .systemFont(ofSize: 11)
        anchorTitle.textColor = .secondaryLabelColor

        let grid = AnchorGridView(frame: .zero)
        grid.setFrameOrigin(NSPoint(x: 196, y: 2))

        let linker = AspectLinker(width: widthField, height: heightField,
                                  ratio: ratio, aspect: CGFloat(width) / CGFloat(max(1, height)))
        widthField.target = linker
        widthField.action = #selector(AspectLinker.widthChanged)
        heightField.target = linker
        heightField.action = #selector(AspectLinker.heightChanged)

        let sampleLabel = NSTextField(labelWithString: "Scaling:")
        sampleLabel.frame = NSRect(x: 0, y: top - 88, width: 60, height: 20)
        let samplePopup = NSPopUpButton(frame: NSRect(x: 64, y: top - 90, width: 128, height: 24))
        samplePopup.addItems(withTitles: Resampling.allCases.map(\.rawValue))
        samplePopup.selectItem(withTitle: (resampling ?? .pixels).rawValue)
        samplePopup.toolTip = "Pixels keeps hard edges, for pixel art. Bilinear and Smooth "
            + "interpolate, Lanczos sharpens an enlargement, and Box Average is the one to shrink with."

        var controls: [NSView] = [widthLabel, widthField, heightLabel, heightField, ratio]
        if showsAnchor { controls += [anchorTitle, grid] }
        if showsResampling { controls += [sampleLabel, samplePopup] }
        controls.forEach { container.addSubview($0) }
        alert.accessoryView = container
        objc_setAssociatedObject(alert, &AspectLinker.key, linker, .OBJC_ASSOCIATION_RETAIN)

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            completion(SizeChoice(size: CGSize(width: max(1, widthField.integerValue),
                                               height: max(1, heightField.integerValue)),
                                  anchor: grid.anchor,
                                  keepsProportions: ratio.state == .on,
                                  resampling: Resampling(rawValue: samplePopup.titleOfSelectedItem ?? "")
                                      ?? .pixels))
        }
    }

    /// What the user chose in the target-file-size sheet.
    struct FileSizeChoice {
        let format: FileSizeExport.Format
        let range: FileSizeExport.Range
        let method: FileSizeExport.Method
        let resampling: Resampling
        let allowsEnlarging: Bool
    }

    /// Collects a range of file sizes to hit, and how the search is allowed to
    /// hit it. Sizes are in kilobytes, which is the unit an upload limit is
    /// usually quoted in.
    static func fileSizeSheet(format: FileSizeExport.Format,
                              minKB: Double,
                              maxKB: Double,
                              method: FileSizeExport.Method,
                              resampling: Resampling,
                              in window: NSWindow,
                              completion: @escaping (FileSizeChoice?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Export to a File Size"
        alert.informativeText = "Sketchy encodes the flattened image over and over, trading quality "
            + "and pixels, until the file lands between these two sizes."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")

        let row: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: row * 5))
        func label(_ text: String, row index: Int) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: container.frame.height - row * CGFloat(index + 1) + 4,
                                 width: 92, height: 18)
            return field
        }
        func y(_ index: Int) -> CGFloat { container.frame.height - row * CGFloat(index + 1) }

        let formatPopup = NSPopUpButton(frame: NSRect(x: 96, y: y(0), width: 110, height: 24))
        formatPopup.addItems(withTitles: FileSizeExport.Format.allCases.map(\.rawValue))
        formatPopup.selectItem(withTitle: format.rawValue)
        formatPopup.toolTip = "PNG and TIFF have no quality to trade, so only their dimensions can move."

        let minField = NSTextField(string: String(format: "%g", minKB))
        minField.frame = NSRect(x: 96, y: y(1) + 1, width: 76, height: 22)
        let toLabel = NSTextField(labelWithString: "to")
        toLabel.frame = NSRect(x: 178, y: y(1) + 4, width: 20, height: 18)
        let maxField = NSTextField(string: String(format: "%g", maxKB))
        maxField.frame = NSRect(x: 200, y: y(1) + 1, width: 76, height: 22)
        let unit = NSTextField(labelWithString: "KB")
        unit.frame = NSRect(x: 282, y: y(1) + 4, width: 30, height: 18)
        unit.textColor = .secondaryLabelColor

        let methodPopup = NSPopUpButton(frame: NSRect(x: 96, y: y(2), width: 220, height: 24))
        methodPopup.addItems(withTitles: FileSizeExport.Method.allCases.map(\.rawValue))
        methodPopup.selectItem(withTitle: method.rawValue)

        let samplePopup = NSPopUpButton(frame: NSRect(x: 96, y: y(3), width: 150, height: 24))
        samplePopup.addItems(withTitles: Resampling.allCases.map(\.rawValue))
        samplePopup.selectItem(withTitle: resampling.rawValue)
        samplePopup.toolTip = "How the image is scaled when the search has to shed pixels."

        let enlarge = NSButton(checkboxWithTitle: "Allow enlarging to reach the minimum",
                               target: nil, action: nil)
        enlarge.frame = NSRect(x: 96, y: y(4), width: 280, height: 20)

        let controls: [NSView] = [label("Format:", row: 0), formatPopup,
                                  label("Target size:", row: 1), minField, toLabel, maxField, unit,
                                  label("Method:", row: 2), methodPopup,
                                  label("Scaling:", row: 3), samplePopup,
                                  enlarge]
        controls.forEach { container.addSubview($0) }
        alert.accessoryView = container

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            let low = max(0, minField.doubleValue)
            let high = max(low, maxField.doubleValue)
            completion(FileSizeChoice(
                format: FileSizeExport.Format(rawValue: formatPopup.titleOfSelectedItem ?? "") ?? .jpeg,
                range: FileSizeExport.Range(minKB: low, maxKB: max(1, high)),
                method: FileSizeExport.Method(rawValue: methodPopup.titleOfSelectedItem ?? "")
                    ?? .qualityThenDimensions,
                resampling: Resampling(rawValue: samplePopup.titleOfSelectedItem ?? "") ?? .smooth,
                allowsEnlarging: enlarge.state == .on))
        }
    }

    static func layerProperties(for layer: Layer, in window: NSWindow, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Layer Properties"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 96))
        let nameField = NSTextField(string: layer.name)
        nameField.frame = NSRect(x: 74, y: 70, width: 210, height: 22)
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 72, width: 70, height: 18)

        let visible = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
        visible.frame = NSRect(x: 74, y: 46, width: 120, height: 20)
        visible.state = layer.isVisible ? .on : .off

        let blend = NSPopUpButton(frame: NSRect(x: 74, y: 20, width: 160, height: 22))
        blend.addItems(withTitles: LayerBlendMode.allCases.map(\.rawValue))
        blend.selectItem(withTitle: layer.blendMode.rawValue)
        let blendLabel = NSTextField(labelWithString: "Blend:")
        blendLabel.frame = NSRect(x: 0, y: 22, width: 70, height: 18)

        let opacity = NSSlider(value: Double(layer.opacity * 100), minValue: 0, maxValue: 100, target: nil, action: nil)
        opacity.frame = NSRect(x: 74, y: 0, width: 160, height: 18)
        let opacityLabel = NSTextField(labelWithString: "Opacity:")
        opacityLabel.frame = NSRect(x: 0, y: 0, width: 70, height: 18)

        [nameLabel, nameField, visible, blendLabel, blend, opacityLabel, opacity].forEach { container.addSubview($0) }
        alert.accessoryView = container

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(false); return }
            layer.name = nameField.stringValue
            layer.isVisible = (visible.state == .on)
            layer.blendMode = LayerBlendMode(rawValue: blend.titleOfSelectedItem ?? "") ?? .normal
            layer.opacity = CGFloat(opacity.doubleValue / 100)
            completion(true)
        }
    }

    /// Asks for one number of pixels, for the Select ▸ Modify commands.
    static func pixels(title: String, label: String, value: Double,
                       in window: NSWindow, completion: @escaping (Double?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        let caption = NSTextField(labelWithString: label)
        caption.frame = NSRect(x: 0, y: 4, width: 96, height: 18)
        let field = NSTextField(string: String(format: "%g", value))
        field.frame = NSRect(x: 100, y: 2, width: 80, height: 22)
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 1000
        formatter.maximumFractionDigits = 1
        field.formatter = formatter
        let unit = NSTextField(labelWithString: "pixels")
        unit.frame = NSRect(x: 186, y: 4, width: 54, height: 18)
        [caption, field, unit].forEach(container.addSubview)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            completion(field.doubleValue)
        }
    }

    /// Generic one- or two-slider effect sheet with a live preview callback.
    static func sliders(title: String,
                        specs: [(name: String, min: Double, max: Double, value: Double)],
                        in window: NSWindow,
                        preview: @escaping ([Double]) -> Void,
                        completion: @escaping ([Double]?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let rowHeight: CGFloat = 30
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight * CGFloat(specs.count)))
        var sliders: [NSSlider] = []
        let handler = SliderHandler { values in preview(values) }

        for (i, spec) in specs.enumerated() {
            let y = container.frame.height - rowHeight * CGFloat(i + 1)
            let label = NSTextField(labelWithString: spec.name)
            label.frame = NSRect(x: 0, y: y + 4, width: 96, height: 18)
            let slider = NSSlider(value: spec.value, minValue: spec.min, maxValue: spec.max,
                                  target: handler, action: #selector(SliderHandler.changed(_:)))
            slider.frame = NSRect(x: 100, y: y + 2, width: 210, height: 20)
            sliders.append(slider)
            container.addSubview(label)
            container.addSubview(slider)
        }
        handler.sliders = sliders
        alert.accessoryView = container
        objc_setAssociatedObject(alert, &SliderHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            completion(sliders.map(\.doubleValue))
        }
    }
}

/// Keeps the width and height fields of the size sheet in proportion.
final class AspectLinker: NSObject {
    static var key: UInt8 = 0
    private let widthField: NSTextField
    private let heightField: NSTextField
    private let ratio: NSButton
    private let aspect: CGFloat

    init(width: NSTextField, height: NSTextField, ratio: NSButton, aspect: CGFloat) {
        self.widthField = width
        self.heightField = height
        self.ratio = ratio
        self.aspect = aspect
    }

    @objc func widthChanged() {
        guard ratio.state == .on, widthField.integerValue > 0 else { return }
        heightField.integerValue = max(1, Int((CGFloat(widthField.integerValue) / aspect).rounded()))
    }

    @objc func heightChanged() {
        guard ratio.state == .on, heightField.integerValue > 0 else { return }
        widthField.integerValue = max(1, Int((CGFloat(heightField.integerValue) * aspect).rounded()))
    }
}

final class SliderHandler: NSObject {
    static var key: UInt8 = 0
    var sliders: [NSSlider] = []
    private let onChange: ([Double]) -> Void

    init(onChange: @escaping ([Double]) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSSlider) {
        onChange(sliders.map(\.doubleValue))
    }
}
