import AppKit
import UniformTypeIdentifiers

/// A document window: toolbar, tool options bar, canvas, status bar, and the
/// rails that palettes dock into.
final class MainWindowController: NSWindowController, NSToolbarDelegate, CanvasViewDelegate, NSWindowDelegate {

    private(set) var doc: Document
    let settings = ToolSettings()
    private(set) var engine: ToolEngine

    private var canvas: CanvasView!
    private var scrollView: NSScrollView!
    private var optionsBar: ToolOptionsBar!
    private var statusBar: StatusBar!

    /// The palettes are app-wide; this window only owns the rails they dock into.
    let hub: PaletteHub
    let leftRail = DockRail(side: .left)
    let rightRail = DockRail(side: .right)

    var toolsPanel: ToolsPanel { hub.toolsPanel }
    var colorsPanel: ColorsPanel { hub.colorsPanel }
    var historyPanel: HistoryPanel { hub.historyPanel }
    var layersPanel: LayersPanel { hub.layersPanel }
    var dock: DockManager { hub.dock }
    private var documentChip: NSButton?
    private var textOverlay: TextBoxOverlay?
    private var clipboardImage: CGImage?

    init(doc: Document, hub: PaletteHub) {
        self.doc = doc
        self.hub = hub
        self.engine = ToolEngine(doc: doc, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "\(doc.displayName) — Sketchy"
        window.minSize = NSSize(width: 760, height: 520)
        // Documents live as tabs of one window rather than separate windows.
        window.tabbingIdentifier = "SketchyDocument"
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        buildInterface()
        buildToolbar()
        hub.attach(to: self)
        selectTool(settings.tool)
        if window.frameAutosaveName.isEmpty { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Interface

    private func buildInterface() {
        guard let window else { return }
        window.contentView = NSView(frame: window.contentLayoutRect)
        guard let content = window.contentView else { return }

        let full = content.bounds

        optionsBar = ToolOptionsBar(settings: settings)
        optionsBar.frame = NSRect(x: 0, y: full.height - 34, width: full.width, height: 34)
        optionsBar.autoresizingMask = [.width, .minYMargin]
        optionsBar.onChange = { [weak self] in self?.canvas.needsDisplay = true }
        optionsBar.onToolChange = { [weak self] tool in self?.selectTool(tool) }

        canvas = CanvasView(document: doc, engine: engine, settings: settings)
        canvas.delegate = self

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 24, width: full.width, height: full.height - 58))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        scrollView.documentView = canvas
        scrollView.contentView.postsBoundsChangedNotifications = true

        statusBar = StatusBar()
        statusBar.frame = NSRect(x: 0, y: 0, width: full.width, height: 24)
        statusBar.autoresizingMask = [.width, .maxYMargin]
        statusBar.onZoomSlider = { [weak self] z in self?.canvas.setZoom(z, anchoredAt: nil) }

        // Showing or hiding the tab bar resizes the content view without
        // resizing the window, so watch the view rather than the window.
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: content)

        content.addSubview(scrollView)
        content.addSubview(leftRail)
        content.addSubview(rightRail)
        content.addSubview(optionsBar)
        content.addSubview(statusBar)
        layoutMainArea()

        statusBar.setDocumentSize(doc.size)
        statusBar.setZoom(canvas.zoom)

        // The canvas can only size itself once it is inside the scroll view.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            canvas.resizeToFit()
            canvas.refresh()
        }

        engine.onColorPicked = { [weak self] color, isSecondary in
            self?.colorsPanel.setColor(color, secondary: isSecondary)
        }
        engine.onStatus = { [weak self] message in
            guard let self else { return }
            statusBar.flash(message, thenHintFor: settings.tool)
            canvas.needsDisplay = true
        }
    }

    @objc private func contentFrameChanged() {
        layoutMainArea()
    }

    /// Lays the canvas out between whichever dock rails currently hold palettes.
    func layoutMainArea() {
        guard let content = window?.contentView, scrollView != nil else { return }
        let top = content.bounds.height - 34   // options bar
        let bottom: CGFloat = 24               // status bar
        let height = max(0, top - bottom)

        func width(of rail: DockRail) -> CGFloat {
            if !rail.isEmpty { return rail.width }
            return rail.isTargeted ? 160 : 0   // preview the rail while dragging over it
        }
        let leftWidth = width(of: leftRail)
        let rightWidth = width(of: rightRail)

        leftRail.frame = NSRect(x: 0, y: bottom, width: leftWidth, height: height)
        rightRail.frame = NSRect(x: content.bounds.width - rightWidth, y: bottom,
                                 width: rightWidth, height: height)
        leftRail.isHidden = leftWidth == 0
        rightRail.isHidden = rightWidth == 0
        scrollView.frame = NSRect(x: leftWidth, y: bottom,
                                  width: max(0, content.bounds.width - leftWidth - rightWidth),
                                  height: height)
        optionsBar.frame = NSRect(x: 0, y: content.bounds.height - 34,
                                  width: content.bounds.width, height: 34)
        statusBar.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: 24)
        leftRail.layoutBoxes()
        rightRail.layoutBoxes()
        canvas?.resizeToFit()
    }

    /// Puts down anything still floating above the canvas. Document-wide
    /// commands rebuild every layer from its bitmap, so a pending paste or
    /// shape would simply vanish if it were left hovering.
    func commitPendingEdits() {
        commitTextOverlay()
        engine.commitSession()
        engine.commitFloatingPixels()
    }

    /// Redraws the canvas without touching the palettes.
    func refreshCanvas() {
        canvas.refresh()
    }

    func refreshPanels() {
        guard hub.activeController === self else { canvas.refresh(); return }
        layersPanel.reload()
        historyPanel.reload()
        canvas.refresh()
        statusBar.setDocumentSize(doc.size)
        window?.title = "\(doc.displayName) — Sketchy"
        documentChip?.title = doc.displayName
        window?.isDocumentEdited = doc.isDirty
    }

    func selectTool(_ tool: ToolID) {
        // Anything still floating is put down before the tool changes under it.
        if tool != settings.tool {
            engine.commitSession()
            if tool != .moveSelectedPixels, engine.commitFloatingPixels() {
                refreshPanels()
            }
        }
        settings.tool = tool
        toolsPanel.select(tool)
        optionsBar.rebuild()
        statusBar.setHint(for: tool)
        canvas.window?.invalidateCursorRects(for: canvas)
        canvas.needsDisplay = true
    }

    // MARK: - Toolbar

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "SketchyMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        window?.titlebarAppearsTransparent = false
    }

    private enum TB {
        static let new = NSToolbarItem.Identifier("new")
        static let open = NSToolbarItem.Identifier("open")
        static let save = NSToolbarItem.Identifier("save")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let deselect = NSToolbarItem.Identifier("deselect")
        static let crop = NSToolbarItem.Identifier("crop")
        static let tools = NSToolbarItem.Identifier("tools")
        static let history = NSToolbarItem.Identifier("history")
        static let layers = NSToolbarItem.Identifier("layers")
        static let colors = NSToolbarItem.Identifier("colors")
        static let title = NSToolbarItem.Identifier("docTitle")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.new, TB.open, TB.save, .space, TB.undo, TB.redo, .space, TB.deselect, TB.crop,
         .flexibleSpace, TB.title, .flexibleSpace, TB.tools, TB.history, TB.layers, TB.colors]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == TB.title {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Document"
            let button = NSButton(title: doc.displayName, target: nil, action: nil)
            button.bezelStyle = .recessed
            button.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 12)
            button.isEnabled = false
            documentChip = button
            item.view = button
            return item
        }
        let spec: (String, String, Selector)
        switch id {
        case TB.new:      spec = ("doc.badge.plus", "New", #selector(newDocument(_:)))
        case TB.open:     spec = ("folder", "Open", #selector(openDocument(_:)))
        case TB.save:     spec = ("square.and.arrow.down", "Save", #selector(saveDocument(_:)))
        case TB.undo:     spec = ("arrow.uturn.backward", "Undo", #selector(undoEdit(_:)))
        case TB.redo:     spec = ("arrow.uturn.forward", "Redo", #selector(redoEdit(_:)))
        case TB.deselect: spec = ("xmark.square", "Deselect", #selector(deselect(_:)))
        case TB.crop:     spec = ("crop", "Crop to Selection", #selector(cropToSelection(_:)))
        case TB.tools:    spec = ("wrench.and.screwdriver", "Tools", #selector(toggleToolsPanel(_:)))
        case TB.history:  spec = ("clock.arrow.circlepath", "History", #selector(toggleHistoryPanel(_:)))
        case TB.layers:   spec = ("square.stack.3d.up", "Layers", #selector(toggleLayersPanel(_:)))
        case TB.colors:   spec = ("paintpalette", "Colors", #selector(toggleColorsPanel(_:)))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = spec.1
        item.toolTip = spec.1
        item.image = NSImage(systemSymbolName: spec.0, accessibilityDescription: spec.1)
        item.target = self
        item.action = spec.2
        item.isBordered = true
        return item
    }

    // MARK: - CanvasViewDelegate

    func canvasDidChangeZoom(_ view: CanvasView) {
        statusBar.setZoom(view.zoom)
    }

    func canvas(_ view: CanvasView, didHoverAt point: CGPoint?) {
        statusBar.setCursor(point)
    }

    func canvasWantsDelete(_ view: CanvasView) {
        deleteSelection(nil)
    }

    func canvas(_ view: CanvasView, didAdjustSetting message: String) {
        optionsBar.rebuild()
        statusBar.flash(message, thenHintFor: settings.tool)
        canvas.needsDisplay = true
    }

    func canvasDidCommitEdit(_ view: CanvasView) {
        refreshPanels()
    }

    func canvasDidChangeMeasurement(_ view: CanvasView) {
        statusBar.setMeasurement(engine.measuredRect)
    }

    func canvasWantsTextEntry(_ view: CanvasView, in box: CGRect) {
        commitTextOverlay()
        let font = fontForSettings()
        // A plain click gets a box wide enough for a line of text; a drag says
        // exactly how big it should be.
        let imageBox = box.width < 1 || box.height < 1
            ? CGRect(x: box.minX, y: box.minY - font.pointSize * 1.6,
                     width: 320, height: font.pointSize * 1.6)
            : box
        let overlay = TextBoxOverlay(frame: .zero, font: font, color: colorsPanel.primary)
        overlay.onCommit = { [weak self] in self?.commitTextOverlay() }
        overlay.onCancel = { [weak self] in
            self?.canvas.removeTextBox()
            self?.textOverlay = nil
        }
        view.showTextBox(overlay, at: imageBox)
        textOverlay = overlay
    }

    private func fontForSettings() -> NSFont {
        var font = NSFont(name: settings.fontName, size: settings.fontSize)
            ?? .systemFont(ofSize: settings.fontSize)
        var traits: NSFontTraitMask = []
        if settings.bold { traits.insert(.boldFontMask) }
        if settings.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        }
        return font
    }

    @objc func commitTextOverlay() {
        guard let overlay = textOverlay else { return }
        let text = overlay.string
        let box = overlay.imageBox
        canvas.removeTextBox()
        textOverlay = nil
        guard !text.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: fontForSettings(),
            .foregroundColor: colorsPanel.primary
        ]
        if settings.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        engine.commitText(NSAttributedString(string: text, attributes: attrs), in: box)
        refreshPanels()
    }

    // MARK: - Document lifecycle

    func replace(doc newDoc: Document) {
        doc = newDoc
        engine = ToolEngine(doc: newDoc, settings: settings)
        engine.primaryColor = colorsPanel.primary
        engine.secondaryColor = colorsPanel.secondary
        engine.onColorPicked = { [weak self] color, isSecondary in
            self?.colorsPanel.setColor(color, secondary: isSecondary)
        }
        canvas.replaceDocument(newDoc, engine: engine)
        historyPanel.attach(newDoc)
        layersPanel.attach(newDoc)
        canvas.zoomToFit()
        if canvas.zoom > 1 { canvas.zoom = 1 }
        refreshPanels()
    }

    /// New images open as another tab rather than replacing this one.
    @objc func newDocument(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newDocument(sender)
    }

    /// True for a brand new, untouched canvas — safe to reuse when opening a file.
    var canBeReplaced: Bool {
        doc.fileURL == nil && !doc.isDirty && doc.layers.count == 1 && doc.history.entries.count <= 1
    }

    /// Sketchy's own layered document type.
    static let nativeType = UTType(filenameExtension: Document.nativeExtension, conformingTo: .data)
        ?? UTType.data

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [MainWindowController.nativeType,
                                     .png, .jpeg, .tiff, .bmp, .gif, .heic, .webP]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                do {
                    let opened = try Document.open(url: url)
                    // Reuse an untouched canvas, otherwise open the file in a tab.
                    if canBeReplaced {
                        replace(doc: opened)
                    } else {
                        (NSApp.delegate as? AppDelegate)?.present(opened)
                    }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        engine.commitSession()
        engine.commitFloatingPixels()
        commitTextOverlay()
        if let url = doc.fileURL {
            do { try doc.write(to: url); refreshPanels() }
            catch { NSAlert(error: error).runModal() }
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        engine.commitSession()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [MainWindowController.nativeType, .png, .jpeg, .tiff, .bmp, .gif]
        let keepsLayers = doc.layers.count > 1 || doc.isNativeFile
        panel.nameFieldStringValue = doc.displayName + (keepsLayers ? ".sketchy" : ".png")
        panel.message = "PNG, JPEG, TIFF, BMP and GIF are flattened. .sketchy keeps every layer."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard confirmFlatten(for: url) else { return }
            do { try doc.write(to: url); refreshPanels() }
            catch { NSAlert(error: error).runModal() }
        }
    }

    /// Checks a proposed canvas size before anything is allocated. Returns
    /// false when the size is refused, or when the user backs out of a size
    /// big enough to be worth a warning.
    func approveCanvasSize(width: Int, height: Int, layers: Int = 1) -> Bool {
        switch Document.verdict(width: width, height: height, layers: layers) {
        case .fine:
            return true

        case .heavy(let bytes):
            let alert = NSAlert()
            alert.messageText = "That is a large canvas"
            let past = max(width, height) > Document.comfortableSide
                ? " Anything past \(Document.comfortableSide) pixels a side is beyond what Sketchy is built for."
                : ""
            alert.informativeText = String(
                format: "%d × %d with %d layer%@ needs about %.1f GB while you work on it. "
                    + "Sketchy will be slow, and other apps may suffer.%@",
                width, height, layers, layers == 1 ? "" : "s",
                Double(bytes) / 1_000_000_000, past)
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn

        case .tooLarge(let reason):
            let alert = NSAlert()
            alert.messageText = "That canvas is too large"
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    /// Confirms before a multi-layer document is flattened into a flat format.
    private func confirmFlatten(for url: URL) -> Bool {
        guard doc.layers.count > 1,
              !Document.isNative(url) else { return true }
        let alert = NSAlert()
        alert.messageText = "Flatten " + url.lastPathComponent + "?"
        alert.informativeText = "\(doc.layers.count) layers will be merged into one. "
            + "Save as .sketchy to keep them."
        alert.addButton(withTitle: "Flatten and Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Edit menu

    @objc func undoEdit(_ sender: Any?) {
        // Uncommitted work is discarded first, matching Paint.NET.
        if engine.session != nil { engine.cancelSession(); return }
        if engine.hasFloatingPixels { engine.cancelFloatingPixels(); refreshPanels(); return }
        doc.undo()
        refreshPanels()
    }
    @objc func redoEdit(_ sender: Any?) { doc.redo(); refreshPanels() }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        deleteSelection(sender)
    }

    @objc func copy(_ sender: Any?) {
        guard let layer = doc.selectedLayer, let img = layer.image else { return }
        let sel = doc.selectionPath ?? CGPath(rect: doc.bounds, transform: nil)
        let box = sel.boundingBoxOfPath.integral.intersection(doc.bounds)
        guard !box.isEmpty else { return }
        let cut = Layer(width: Int(box.width), height: Int(box.height), name: "clip")
        cut.context.saveGState()
        cut.context.translateBy(x: -box.minX, y: -box.minY)
        cut.context.addPath(sel)
        cut.context.clip(using: .evenOdd)
        cut.context.draw(img, in: doc.bounds)
        cut.context.restoreGState()
        clipboardImage = cut.image

        if let cg = clipboardImage {
            let rep = NSBitmapImageRep(cgImage: cg)
            let nsImage = NSImage(size: NSSize(width: cg.width, height: cg.height))
            nsImage.addRepresentation(rep)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([nsImage])
        }
    }

    /// The image on the clipboard, preferring what this app last copied so a
    /// round trip through the pasteboard cannot lose anything.
    private var pasteboardImage: CGImage? {
        if let clipboardImage { return clipboardImage }
        guard let pasted = NSPasteboard.general
            .readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else { return nil }
        return pasted.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @objc func paste(_ sender: Any?) { paste(scale: .actualSize) }

    /// Stretches the paste over the whole canvas, proportions be damned.
    @objc func pasteStretchedToCanvas(_ sender: Any?) { paste(scale: .stretchToCanvas) }

    /// Scales the paste to the canvas without distorting it, centred.
    @objc func pasteFitToCanvas(_ sender: Any?) { paste(scale: .fitToCanvas) }

    /// The pixels go into the layer as they are: a paste is an edit, not a
    /// question, so nothing is asked and nothing has to be dropped after.
    /// Anything past the canvas edge is clipped away, and the pasted region
    /// becomes the selection so it can be moved straight away.
    private func paste(scale: Document.PasteScale) {
        guard let image = pasteboardImage else { return }
        guard doc.selectedRasterLayer != nil else { return groupWarning() }
        // Whatever was pending is put down first, so the paste is the top step.
        commitPendingEdits()
        doc.paste(image, scale: scale, resampling: settings.resampling)
        refreshPanels()
    }

    @objc func pasteIntoNewLayer(_ sender: Any?) {
        doc.addLayer(named: "Pasted Layer")
        paste(sender)
    }

    /// ⌫ / ⌦: throw away the pending shape if there is one, otherwise erase the
    /// selection — or the whole layer when nothing is selected.
    @objc func deleteSelection(_ sender: Any?) {
        if engine.session != nil {
            engine.cancelSession()
            return
        }
        // Delete throws away a floating paste rather than erasing the layer.
        if engine.hasFloatingPixels {
            engine.cancelFloatingPixels()
            refreshPanels()
            return
        }
        commitTextOverlay()
        doc.eraseSelection()
        refreshPanels()
    }

    @objc func fillSelection(_ sender: Any?) {
        guard let layer = doc.selectedRasterLayer else { return groupWarning() }
        let sel = doc.selectionPath ?? CGPath(rect: doc.bounds, transform: nil)
        layer.context.saveGState()
        layer.context.addPath(sel)
        layer.context.clip(using: .evenOdd)
        layer.context.setFillColor(colorsPanel.primary.srgb.cgColor)
        layer.context.fill(doc.bounds)
        layer.context.restoreGState()
        doc.commit("Fill Selection")
        refreshPanels()
    }

    @objc override func selectAll(_ sender: Any?) { doc.selectAll() }
    @objc func deselect(_ sender: Any?) { doc.deselect() }
    @objc func invertSelection(_ sender: Any?) { doc.invertSelection() }

    // MARK: - Image menu

    @objc func cropToSelection(_ sender: Any?) {
        commitPendingEdits()
        guard let sel = doc.selectionPath else { return }
        doc.crop(to: sel.boundingBoxOfPath)
        canvas.zoomToFit()
        if canvas.zoom > 1 { canvas.zoom = 1 }
        refreshPanels()
    }

    @objc func resizeImage(_ sender: Any?) {
        commitPendingEdits()
        guard let window else { return }
        Dialogs.sizeSheet(title: "Image Size",
                          message: "Resample the image. With proportions kept, the anchor decides "
                            + "where it sits inside the new size.",
                          width: doc.width, height: doc.height,
                          anchorLabel: "Anchor", resampling: settings.resampling,
                          in: window) { [weak self] choice in
            guard let self, let choice else { return }
            guard approveCanvasSize(width: Int(choice.size.width), height: Int(choice.size.height),
                                    layers: doc.layers.count) else { return }
            settings.resampling = choice.resampling
            // Only a proportional resize can leave space for the anchor to place.
            doc.resizeImage(to: choice.size, anchor: choice.anchor,
                            fit: choice.keepsProportions, resampling: choice.resampling)
            refreshPanels()
        }
    }

    @objc func resizeCanvas(_ sender: Any?) {
        commitPendingEdits()
        guard let window else { return }
        Dialogs.sizeSheet(title: "Canvas Size",
                          message: "Change the canvas without scaling the image. The anchor is "
                            + "where the current image stays put.",
                          width: doc.width, height: doc.height,
                          anchorLabel: "Anchor", in: window) { [weak self] choice in
            guard let self, let choice else { return }
            guard approveCanvasSize(width: Int(choice.size.width), height: Int(choice.size.height),
                                    layers: doc.layers.count) else { return }
            doc.resizeCanvas(to: choice.size, anchor: choice.anchor)
            refreshPanels()
        }
    }

    @objc func rotate90CW(_ sender: Any?) { commitPendingEdits(); doc.rotate(turns: 3); refreshPanels() }
    @objc func rotate90CCW(_ sender: Any?) { commitPendingEdits(); doc.rotate(turns: 1); refreshPanels() }
    @objc func rotate180(_ sender: Any?) { commitPendingEdits(); doc.rotate(turns: 2); refreshPanels() }
    @objc func flipHorizontal(_ sender: Any?) { commitPendingEdits(); doc.flip(horizontal: true); refreshPanels() }
    @objc func flipVertical(_ sender: Any?) { commitPendingEdits(); doc.flip(horizontal: false); refreshPanels() }
    @objc func flattenImage(_ sender: Any?) { commitPendingEdits(); doc.flatten(); refreshPanels() }

    // MARK: - Layers menu

    @objc func addLayer(_ sender: Any?) {
        commitPendingEdits()
        guard approveCanvasSize(width: doc.width, height: doc.height,
                                layers: doc.layers.count + 1) else { return }
        doc.addLayer()
        refreshPanels()
    }
    @objc func deleteLayer(_ sender: Any?) { commitPendingEdits(); doc.deleteSelectedLayer(); refreshPanels() }
    @objc func duplicateLayer(_ sender: Any?) { commitPendingEdits(); doc.duplicateSelectedLayer(); refreshPanels() }

    /// Says why nothing happened when a group is selected.
    private func groupWarning() {
        statusBar.flash("That is a group — select a layer inside it first",
                        thenHintFor: settings.tool)
    }

    @objc func groupLayer(_ sender: Any?) {
        commitPendingEdits()
        doc.groupSelected()
        refreshPanels()
    }

    /// Ungroups the selection, or the group holding it when a member is selected.
    @objc func ungroupLayer(_ sender: Any?) {
        commitPendingEdits()
        let index = doc.selectedLayer?.isGroup == true
            ? doc.selectedLayerIndex
            : doc.parentGroup(of: doc.selectedLayerIndex)
        guard let index else { return }
        doc.ungroup(at: index)
        refreshPanels()
    }
    @objc func mergeLayerDown(_ sender: Any?) { commitPendingEdits(); doc.mergeLayerDown(); refreshPanels() }
    @objc func flipLayerHorizontal(_ sender: Any?) { commitPendingEdits(); doc.flip(horizontal: true, layerOnly: true); refreshPanels() }
    @objc func flipLayerVertical(_ sender: Any?) { commitPendingEdits(); doc.flip(horizontal: false, layerOnly: true); refreshPanels() }

    @objc func rotateZoomLayer(_ sender: Any?) {
        commitPendingEdits()
        guard let layer = doc.selectedRasterLayer else { return groupWarning() }
        guard let window else { return }
        let snapshot = layer.image

        func apply(_ v: [Double]) {
            layer.restore(from: snapshot)
            doc.transformLayer(layer,
                               angle: CGFloat(v[0]) * .pi / 180,
                               scale: CGFloat(v[1]),
                               offset: CGPoint(x: CGFloat(v[2]), y: CGFloat(v[3])))
            canvas.refresh()
        }

        Dialogs.sliders(title: "Rotate / Zoom Layer",
                        specs: [("Angle\u{00B0}", -180, 180, 0),
                                ("Zoom", 0.1, 4, 1),
                                ("Pan X", -500, 500, 0),
                                ("Pan Y", -500, 500, 0)],
                        in: window,
                        preview: { apply($0) }) { [weak self] values in
            guard let self else { return }
            if let values {
                apply(values)
                doc.commit("Rotate / Zoom Layer")
            } else {
                layer.restore(from: snapshot)
                canvas.refresh()
            }
            refreshPanels()
        }
    }

    @objc func rotateImageArbitrary(_ sender: Any?) {
        commitPendingEdits()
        guard let window else { return }
        let snapshots = doc.layers.map { $0.image }

        func apply(_ v: [Double]) {
            for (layer, snap) in zip(doc.layers, snapshots) {
                layer.restore(from: snap)
                doc.transformLayer(layer, angle: CGFloat(v[0]) * .pi / 180,
                                   scale: CGFloat(v[1]), offset: .zero)
            }
            canvas.refresh()
        }

        Dialogs.sliders(title: "Rotate Image",
                        specs: [("Angle\u{00B0}", -180, 180, 0), ("Zoom", 0.1, 4, 1)],
                        in: window,
                        preview: { apply($0) }) { [weak self] values in
            guard let self else { return }
            if let values {
                apply(values)
                doc.commit("Rotate Image")
            } else {
                for (layer, snap) in zip(doc.layers, snapshots) { layer.restore(from: snap) }
                canvas.refresh()
            }
            refreshPanels()
        }
    }

    @objc func showLayerProperties() {
        guard let window, let layer = doc.selectedLayer else { return }
        Dialogs.layerProperties(for: layer, in: window) { [weak self] changed in
            guard changed, let self else { return }
            doc.commit("Layer Properties")
            refreshPanels()
        }
    }

    // MARK: - View menu

    @objc func zoomIn(_ sender: Any?) { canvas.setZoom(canvas.zoom * 1.25, anchoredAt: nil) }
    @objc func zoomOut(_ sender: Any?) { canvas.setZoom(canvas.zoom / 1.25, anchoredAt: nil) }
    @objc func zoomActual(_ sender: Any?) { canvas.setZoom(1, anchoredAt: nil) }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    private func togglePalette(_ id: String) {
        guard let palette = dock.palette(id: id) else { return }
        dock.toggle(palette)
    }

    @objc func toggleToolsPanel(_ sender: Any?) { togglePalette("tools") }
    @objc func toggleColorsPanel(_ sender: Any?) { togglePalette("colors") }
    @objc func toggleHistoryPanel(_ sender: Any?) { togglePalette("history") }
    @objc func toggleLayersPanel(_ sender: Any?) { togglePalette("layers") }

    // MARK: - Docking commands

    /// Menu items carry "<palette id>:<side>" so one action covers them all.
    @objc func dockPalette(_ sender: NSMenuItem) {
        let parts = (sender.representedObject as? String ?? "").split(separator: ":")
        guard parts.count == 2, let palette = dock.palette(id: String(parts[0])),
              let side = DockSide(rawValue: String(parts[1])) else { return }
        if side == .floating { dock.float(palette) } else { dock.dock(palette, to: side) }
    }

    @objc func dockAllLeft(_ sender: Any?) {
        for p in dock.palettes { dock.dock(p, to: .left) }
    }

    @objc func dockAllRight(_ sender: Any?) {
        for p in dock.palettes { dock.dock(p, to: .right) }
    }

    @objc func togglePalettesInFront(_ sender: Any?) {
        hub.keepsPalettesInFront.toggle()
    }

    @objc func resetPaletteLayout(_ sender: Any?) {
        dock.resetLayout()
        if let window { hub.positionPanels(around: window) }
    }

    // MARK: - Adjustments & Effects

    /// Runs a filter with a live-preview sheet; sliders re-apply from a snapshot.
    private func runEffect(title: String,
                           specs: [(name: String, min: Double, max: Double, value: Double)],
                           build: @escaping ([Double]) -> ((CIImage) -> CIImage?)) {
        commitPendingEdits()
        guard let layer = doc.selectedRasterLayer else { return groupWarning() }
        guard let window else { return }
        let snapshot = layer.image

        func apply(_ values: [Double]) {
            layer.restore(from: snapshot)
            _ = ImageEffects.apply(build(values), to: layer, selection: doc.selectionPath)
            canvas.refresh()
        }

        if specs.isEmpty {
            apply([])
            doc.commit(title)
            refreshPanels()
            return
        }

        apply(specs.map(\.value))
        Dialogs.sliders(title: title, specs: specs, in: window, preview: { apply($0) }) { [weak self] values in
            guard let self else { return }
            if let values {
                apply(values)
                doc.commit(title)
            } else {
                layer.restore(from: snapshot)
                canvas.refresh()
            }
            refreshPanels()
        }
    }

    @objc func adjustBlackAndWhite(_ s: Any?) { runEffect(title: "Black and White", specs: []) { _ in ImageEffects.blackAndWhite } }
    @objc func adjustInvert(_ s: Any?) { runEffect(title: "Invert Colors", specs: []) { _ in ImageEffects.invert } }
    @objc func adjustSepia(_ s: Any?) { runEffect(title: "Sepia", specs: []) { _ in ImageEffects.sepia } }
    @objc func adjustAutoLevel(_ s: Any?) { runEffect(title: "Auto-Level", specs: []) { _ in ImageEffects.autoLevels } }

    @objc func adjustBrightnessContrast(_ s: Any?) {
        runEffect(title: "Brightness / Contrast",
                  specs: [("Brightness", -1, 1, 0), ("Contrast", 0, 3, 1)]) { v in
            { ImageEffects.brightnessContrast($0, brightness: v[0], contrast: v[1]) }
        }
    }

    @objc func adjustHueSaturation(_ s: Any?) {
        runEffect(title: "Hue / Saturation",
                  specs: [("Hue", -3.14, 3.14, 0), ("Saturation", 0, 3, 1)]) { v in
            { ImageEffects.hueSaturation($0, hue: v[0], saturation: v[1]) }
        }
    }

    @objc func adjustCurves(_ s: Any?) {
        runEffect(title: "Curves (Gamma)", specs: [("Gamma", 0.1, 4, 1)]) { v in
            { ImageEffects.curves($0, gamma: v[0]) }
        }
    }

    @objc func adjustPosterize(_ s: Any?) {
        runEffect(title: "Posterize", specs: [("Levels", 2, 32, 6)]) { v in
            { ImageEffects.posterize($0, levels: v[0]) }
        }
    }

    @objc func effectGaussianBlur(_ s: Any?) {
        runEffect(title: "Gaussian Blur", specs: [("Radius", 0, 50, 4)]) { v in
            { ImageEffects.gaussianBlur($0, radius: v[0]) }
        }
    }

    @objc func effectMotionBlur(_ s: Any?) {
        runEffect(title: "Motion Blur", specs: [("Radius", 0, 60, 10), ("Angle", -3.14, 3.14, 0)]) { v in
            { ImageEffects.motionBlur($0, radius: v[0], angle: v[1]) }
        }
    }

    @objc func effectSharpen(_ s: Any?) {
        runEffect(title: "Sharpen", specs: [("Amount", 0, 4, 0.6)]) { v in
            { ImageEffects.sharpen($0, amount: v[0]) }
        }
    }

    @objc func effectGlow(_ s: Any?) {
        runEffect(title: "Glow", specs: [("Radius", 1, 40, 10)]) { v in
            { ImageEffects.glow($0, radius: v[0]) }
        }
    }

    @objc func effectPixelate(_ s: Any?) {
        runEffect(title: "Pixelate", specs: [("Cell Size", 1, 60, 8)]) { v in
            { ImageEffects.pixelate($0, scale: v[0]) }
        }
    }

    @objc func effectEmboss(_ s: Any?) { runEffect(title: "Emboss", specs: []) { _ in ImageEffects.emboss } }
    @objc func effectEdgeDetect(_ s: Any?) { runEffect(title: "Edge Detect", specs: []) { _ in ImageEffects.edgeDetect } }

    @objc func effectAddNoise(_ s: Any?) {
        runEffect(title: "Add Noise", specs: [("Amount", 0, 1, 0.2)]) { v in
            { ImageEffects.noise($0, amount: v[0]) }
        }
    }

    @objc func effectOilPainting(_ s: Any?) {
        runEffect(title: "Oil Painting", specs: [("Brush Size", 1, 30, 6)]) { v in
            { ImageEffects.oilPainting($0, radius: v[0]) }
        }
    }

    @objc func effectTwist(_ s: Any?) {
        runEffect(title: "Twist", specs: [("Amount", -6.28, 6.28, 3)]) { v in
            { ImageEffects.twist($0, amount: v[0]) }
        }
    }

    @objc func effectBulge(_ s: Any?) {
        runEffect(title: "Bulge", specs: [("Amount", -1, 1, 0.5)]) { v in
            { ImageEffects.bulge($0, scale: v[0]) }
        }
    }

    @objc func effectVignette(_ s: Any?) {
        runEffect(title: "Vignette", specs: [("Intensity", 0, 3, 1)]) { v in
            { ImageEffects.vignette($0, intensity: v[0]) }
        }
    }

    // MARK: - Window delegate

    func windowDidResize(_ notification: Notification) {
        layoutMainArea()
        canvas.resizeToFit()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(doc.displayName)” before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveDocument(nil); return !doc.isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        // Tabs share one set of palettes, so they follow the active document.
        if hub.activeController !== self { hub.attach(to: self) }
    }
}
