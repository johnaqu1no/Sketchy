import AppKit

/// One shared set of palettes for the whole app. Document windows are tabs of a
/// single window, so the Tools / Colors / History / Layers palettes follow
/// whichever tab is active instead of being duplicated per document.
final class PaletteHub {
    let toolsPanel = ToolsPanel()
    let colorsPanel = ColorsPanel()
    let historyPanel = HistoryPanel()
    let layersPanel = LayersPanel()
    let dock = DockManager()
    let shortcuts = ToolShortcuts()

    private(set) weak var activeController: MainWindowController?
    private var didRestoreLayout = false

    private static let inFrontKey = "SketchyPalettesInFront"

    /// Palettes sit in the normal window order unless this is turned on.
    var keepsPalettesInFront: Bool {
        didSet {
            UserDefaults.standard.set(keepsPalettesInFront, forKey: PaletteHub.inFrontKey)
            applyPanelLevel()
        }
    }

    private var panels: [FloatingPanel] { [toolsPanel, colorsPanel, historyPanel, layersPanel] }

    private func applyPanelLevel() {
        panels.forEach { $0.keepsInFront = keepsPalettesInFront }
    }

    init() {
        keepsPalettesInFront = UserDefaults.standard.bool(forKey: PaletteHub.inFrontKey)
        toolsPanel.palette.shortcuts = shortcuts
        shortcuts.onChange = { [weak self] in self?.toolsPanel.palette.refreshTooltips() }
        dock.register(Palette(id: "tools", title: "Tools", panel: toolsPanel,
                              dockedHeight: toolsPanel.frame.height))
        dock.register(Palette(id: "colors", title: "Colors", panel: colorsPanel,
                              dockedHeight: colorsPanel.frame.height))
        dock.register(Palette(id: "history", title: "History", panel: historyPanel, dockedHeight: nil))
        dock.register(Palette(id: "layers", title: "Layers", panel: layersPanel, dockedHeight: nil))
        applyPanelLevel()
    }

    /// Rewires every palette to a document window and moves any docked palettes
    /// into that window's rails.
    func attach(to controller: MainWindowController) {
        guard let window = controller.window else { return }
        let previous = activeController
        activeController = controller

        dock.onLayoutChange = { [weak controller] in controller?.layoutMainArea() }
        dock.useRails(left: controller.leftRail, right: controller.rightRail, in: window)

        toolsPanel.onSelect = { [weak controller] tool in controller?.selectTool(tool) }
        toolsPanel.select(controller.settings.tool)

        colorsPanel.onColorsChanged = { [weak self] primary, secondary in
            guard let active = self?.activeController else { return }
            active.engine.primaryColor = primary
            active.engine.secondaryColor = secondary
            active.colorsChanged()
        }
        controller.engine.primaryColor = colorsPanel.primary
        controller.engine.secondaryColor = colorsPanel.secondary

        historyPanel.attach(controller.doc)
        historyPanel.onJump = { [weak controller] index in
            controller?.doc.jumpHistory(to: index)
            controller?.refreshPanels()
        }
        historyPanel.onUndo = { [weak controller] in controller?.undoEdit(nil) }
        historyPanel.onRedo = { [weak controller] in controller?.redoEdit(nil) }

        layersPanel.attach(controller.doc)
        layersPanel.onAdd = { [weak controller] in controller?.doc.addLayer(); controller?.refreshPanels() }
        layersPanel.onDelete = { [weak controller] in controller?.doc.deleteSelectedLayer(); controller?.refreshPanels() }
        layersPanel.onDuplicate = { [weak controller] in controller?.doc.duplicateSelectedLayer(); controller?.refreshPanels() }
        layersPanel.onMerge = { [weak controller] in controller?.doc.mergeLayerDown(); controller?.refreshPanels() }
        layersPanel.onMoveUp = { [weak controller] in
            controller?.doc.moveSelected(up: true)
            controller?.refreshPanels()
        }
        layersPanel.onMoveDown = { [weak controller] in
            controller?.doc.moveSelected(up: false)
            controller?.refreshPanels()
        }
        layersPanel.onGroup = { [weak controller] in controller?.groupLayer(nil) }
        layersPanel.onUngroup = { [weak controller] in controller?.ungroupLayer(nil) }
        layersPanel.onProperties = { [weak controller] in controller?.showLayerProperties() }
        layersPanel.onChange = { [weak self, weak controller] in
            controller?.refreshCanvas()
            self?.layersPanel.reload()
        }

        if !didRestoreLayout {
            didRestoreLayout = true
            positionPanels(around: window)
            [toolsPanel, colorsPanel, historyPanel, layersPanel].forEach { $0.orderFront(nil) }
            dock.restoreLayout()
            for palette in dock.palettes where palette.side == .floating {
                palette.panel.fitContent()
            }
        }
        // The tab we came from now has empty rails, so let it reclaim the space.
        if previous !== controller { previous?.layoutMainArea() }
        controller.layoutMainArea()
        controller.refreshPanels()
    }

    /// Default placement: tools top-left, colors bottom-left, history top-right,
    /// layers bottom-right.
    func positionPanels(around window: NSWindow) {
        let frame = window.frame
        let margin: CGFloat = 16
        let topY = frame.maxY - 110
        toolsPanel.setFrameTopLeftPoint(NSPoint(x: frame.minX + margin, y: topY))
        historyPanel.setFrameTopLeftPoint(
            NSPoint(x: frame.maxX - margin - historyPanel.frame.width, y: topY))
        colorsPanel.setFrameTopLeftPoint(
            NSPoint(x: frame.minX + margin, y: frame.minY + margin + colorsPanel.frame.height))
        layersPanel.setFrameTopLeftPoint(
            NSPoint(x: frame.maxX - margin - layersPanel.frame.width,
                    y: frame.minY + margin + layersPanel.frame.height))
    }

    /// Lifts the palettes above the document window once, without pinning
    /// them there. Clicking the canvas afterwards covers them again, which is
    /// the point: visible at launch, not permanently in the way.
    func bringPalettesForward() {
        guard !keepsPalettesInFront else { return }
        for panel in panels where panel.isVisible { panel.orderFront(nil) }
    }

    /// Hides the floating palettes when the last document tab goes away.
    func hideAll() {
        [toolsPanel, colorsPanel, historyPanel, layersPanel].forEach { $0.orderOut(nil) }
    }
}
