import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    private var controllers: [MainWindowController] = []
    private let hub = PaletteHub()
    private var hasLiftedPalettes = false

    /// Unpinned palettes sit in the normal window order, so activating the app
    /// raises the document window over them. Lift them once the first document
    /// is on screen and activation has settled, otherwise a fresh launch shows
    /// nothing but an empty canvas.
    private func liftPalettesOnce() {
        guard !hasLiftedPalettes else { return }
        hasLiftedPalettes = true
        hub.bringPalettesForward()
        // Activation raises the key window after this call returns, so lift
        // them again once it has run.
        DispatchQueue.main.async { [hub] in hub.bringPalettesForward() }
    }
    private var keyMonitor: Any?
    private var shortcutsWindow: ShortcutsWindowController?

    var frontController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        return controllers.last
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenuBar()
        installToolShortcuts()
        NSApp.activate(ignoringOtherApps: true)
        liftPalettesOnce()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// AppKit only asks for this when the app was not launched with a file, so
    /// double-clicking an image no longer gets a stray blank tab beside it.
    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        controllers.isEmpty
    }

    public func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        present(Document(width: 800, height: 600))
        return true
    }

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(urls: [URL(fileURLWithPath: filename)])
        return true
    }

    /// The modern entry point: Finder hands over every file at once.
    public func application(_ application: NSApplication, open urls: [URL]) {
        open(urls: urls)
    }

    /// Opens each file as a tab, reusing an untouched blank canvas for the first.
    private func open(urls: [URL]) {
        for url in urls {
            do {
                let doc = try Document.open(url: url)
                if let front = frontController, front.canBeReplaced {
                    front.replace(doc: doc)
                } else {
                    present(doc)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Windows

    /// ⌘N asks for a size, then opens the new image as another tab.
    @objc func newDocument(_ sender: Any?) {
        guard let window = frontController?.window else {
            present(Document(width: 800, height: 600))
            return
        }
        Dialogs.sizeSheet(title: "New Image", message: "Choose the canvas size.",
                          width: 800, height: 600, in: window) { [weak self] choice in
            guard let self, let choice else { return }
            let width = Int(choice.size.width)
            let height = Int(choice.size.height)
            guard frontController?.approveCanvasSize(width: width, height: height) ?? true else { return }
            present(Document(width: width, height: height))
        }
    }

    @objc func newTab(_ sender: Any?) {
        present(Document(width: 800, height: 600))
    }

    /// Every document is a tab of the same window.
    func present(_ doc: Document) {
        let controller = MainWindowController(doc: doc, hub: hub)
        let isFirst = controllers.isEmpty
        controllers.append(controller)
        guard let window = controller.window else { return }

        // Tabs share one window frame, so only the window that opens the group
        // remembers its size and position between launches.
        if isFirst { window.setFrameAutosaveName("Sketchy.document") }

        let host = (frontController?.window ?? controllers.dropLast().last?.window)
            .flatMap { $0 === window ? nil : $0 }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        liftPalettesOnce()

        // addTabbedWindow silently does nothing while the host window is still
        // on its way to the window server, so join the tab group a tick later.
        if let host {
            DispatchQueue.main.async {
                host.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.documentWindowClosed(controller)
        }
    }

    /// The palettes are windows too, so the app has to decide for itself when
    /// the last *document* tab is gone.
    private func documentWindowClosed(_ controller: MainWindowController) {
        controllers.removeAll { $0 === controller }
        if controllers.isEmpty {
            hub.hideAll()
            NSApp.terminate(nil)
        }
    }

    /// Single-letter tool switching, skipped while typing.
    private func installToolShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let controller = frontController,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == "[" || chars == "]" {
                let delta: CGFloat = chars == "[" ? -1 : 1
                controller.settings.brushWidth = max(1, min(200, controller.settings.brushWidth + delta))
                controller.selectTool(controller.settings.tool)
                return nil
            }
            // Tools sharing a key cycle, the way Paint.NET does.
            guard let next = hub.shortcuts.nextTool(for: chars, after: controller.settings.tool)
            else { return event }
            controller.selectTool(next)
            return nil
        }
    }

    // MARK: - Menu bar

    private func item(_ title: String, _ selector: Selector?, _ key: String = "",
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private func buildMenuBar() {
        let main = NSMenu()

        // Sketchy
        let appMenu = NSMenu()
        appMenu.addItem(item("About Sketchy", #selector(showAbout), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Tool Shortcuts…", #selector(showShortcuts), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Sketchy", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Sketchy", #selector(NSApplication.terminate(_:)), "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New…", #selector(newDocument(_:)), "n"))
        file.addItem(item("New Tab", #selector(newTab(_:)), "t"))
        file.addItem(item("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
        file.addItem(.separator())
        file.addItem(item("Save", #selector(MainWindowController.saveDocument(_:)), "s"))
        file.addItem(item("Save As…", #selector(MainWindowController.saveDocumentAs(_:)), "S", [.command, .shift]))
        file.addItem(.separator())
        // No key equivalent: ⌘⇧E is Sepia, and export is the rarer command.
        file.addItem(item("Export as Flat Image…",
                          #selector(MainWindowController.exportFlatImage(_:)), ""))
        file.addItem(item("Export to a File Size…",
                          #selector(MainWindowController.exportForFileSize(_:)), ""))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(NSWindow.performClose(_:)), "w"))
        addSubmenu(file, to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", #selector(MainWindowController.undoEdit(_:)), "z"))
        edit.addItem(item("Redo", #selector(MainWindowController.redoEdit(_:)), "Z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(MainWindowController.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(MainWindowController.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(MainWindowController.paste(_:)), "v"))
        edit.addItem(item("Paste Into New Layer", #selector(MainWindowController.pasteIntoNewLayer(_:)), "V", [.command, .shift]))
        edit.addItem(item("Paste Stretched to Canvas",
                          #selector(MainWindowController.pasteStretchedToCanvas(_:)), ""))
        edit.addItem(item("Paste Fit to Canvas",
                          #selector(MainWindowController.pasteFitToCanvas(_:)), ""))
        edit.addItem(.separator())
        // One command, three key codes: the menu displays ⌫ for 0x08, the ⌫ key
        // actually reports 0x7F, and ⌦ (fn-delete) reports NSDeleteFunctionKey.
        edit.addItem(item("Delete", #selector(MainWindowController.deleteSelection(_:)), "\u{8}", []))
        for code in ["\u{7F}", "\u{F728}"] {
            let hidden = item("Delete", #selector(MainWindowController.deleteSelection(_:)), code, [])
            hidden.isHidden = true
            edit.addItem(hidden)
        }
        edit.addItem(item("Fill Selection", #selector(MainWindowController.fillSelection(_:)), "\u{8}", [.command]))
        edit.addItem(.separator())
        edit.addItem(item("Select All", #selector(MainWindowController.selectAll(_:)), "a"))
        edit.addItem(item("Deselect All", #selector(MainWindowController.deselect(_:)), "d"))
        edit.addItem(item("Invert Selection", #selector(MainWindowController.invertSelection(_:)), "i"))
        edit.addItem(item("Select Subject", #selector(MainWindowController.selectSubject(_:)), "a", [.command, .option]))
        edit.addItem(item("Color Range\u{2026}", #selector(MainWindowController.colorRange(_:)), ""))
        let modify = NSMenu(title: "Modify Selection")
        modify.addItem(item("Expand\u{2026}", #selector(MainWindowController.expandSelection(_:)), ""))
        modify.addItem(item("Contract\u{2026}", #selector(MainWindowController.contractSelection(_:)), ""))
        // ⇧F6, as in Photoshop.
        let f6 = String(Character(UnicodeScalar(UInt16(NSF6FunctionKey))!))
        modify.addItem(item("Feather\u{2026}", #selector(MainWindowController.featherSelection(_:)), f6, [.shift]))
        addSubmenu(modify, to: edit)
        addSubmenu(edit, to: main)

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Zoom In", #selector(MainWindowController.zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        view.addItem(item("Actual Size", #selector(MainWindowController.zoomActual(_:)), "0"))
        view.addItem(item("Fit to Window", #selector(MainWindowController.zoomToFit(_:)), "B", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Tools", #selector(MainWindowController.toggleToolsPanel(_:)), "1"))
        view.addItem(item("Colors", #selector(MainWindowController.toggleColorsPanel(_:)), "2"))
        view.addItem(item("History", #selector(MainWindowController.toggleHistoryPanel(_:)), "3"))
        view.addItem(item("Layers", #selector(MainWindowController.toggleLayersPanel(_:)), "4"))
        view.addItem(.separator())

        // Docking: one submenu per palette, plus the bulk commands.
        let palettes = NSMenu(title: "Palettes")
        for (id, name) in [("tools", "Tools"), ("colors", "Colors"),
                           ("history", "History"), ("layers", "Layers")] {
            let sub = NSMenu(title: name)
            for (side, label) in [("left", "Dock Left"), ("right", "Dock Right"), ("floating", "Float")] {
                let entry = NSMenuItem(title: label,
                                       action: #selector(MainWindowController.dockPalette(_:)),
                                       keyEquivalent: "")
                entry.representedObject = "\(id):\(side)"
                sub.addItem(entry)
            }
            let holder = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            holder.submenu = sub
            palettes.addItem(holder)
        }
        palettes.addItem(.separator())
        palettes.addItem(item("Keep Palettes in Front",
                              #selector(MainWindowController.togglePalettesInFront(_:)), ""))
        palettes.addItem(.separator())
        palettes.addItem(item("Dock All Left", #selector(MainWindowController.dockAllLeft(_:)), ""))
        palettes.addItem(item("Dock All Right", #selector(MainWindowController.dockAllRight(_:)), ""))
        palettes.addItem(item("Float All (Reset Layout)", #selector(MainWindowController.resetPaletteLayout(_:)), ""))
        let palettesItem = NSMenuItem(title: "Palettes", action: nil, keyEquivalent: "")
        palettesItem.submenu = palettes
        view.addItem(palettesItem)
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        addSubmenu(view, to: main)

        // Image
        let image = NSMenu(title: "Image")
        image.addItem(item("Crop to Selection", #selector(MainWindowController.cropToSelection(_:)), "X", [.command, .shift]))
        image.addItem(item("Resize Image…", #selector(MainWindowController.resizeImage(_:)), "r"))
        image.addItem(item("Canvas Size…", #selector(MainWindowController.resizeCanvas(_:)), "R", [.command, .shift]))
        image.addItem(.separator())
        image.addItem(item("Flip Horizontal", #selector(MainWindowController.flipHorizontal(_:)), ""))
        image.addItem(item("Flip Vertical", #selector(MainWindowController.flipVertical(_:)), ""))
        image.addItem(item("Rotate 90° Clockwise", #selector(MainWindowController.rotate90CW(_:)), "]", [.command, .shift]))
        image.addItem(item("Rotate 90° Counter-Clockwise", #selector(MainWindowController.rotate90CCW(_:)), "[", [.command, .shift]))
        image.addItem(item("Rotate 180°", #selector(MainWindowController.rotate180(_:)), ""))
        image.addItem(item("Rotate by Angle…", #selector(MainWindowController.rotateImageArbitrary(_:)), ""))
        image.addItem(.separator())
        image.addItem(item("Flatten", #selector(MainWindowController.flattenImage(_:)), "F", [.command, .shift]))
        addSubmenu(image, to: main)

        // Layers
        let layers = NSMenu(title: "Layers")
        layers.addItem(item("Add New Layer", #selector(MainWindowController.addLayer(_:)), "N", [.command, .control]))
        layers.addItem(item("Delete Layer", #selector(MainWindowController.deleteLayer(_:)), "D", [.command, .control]))
        layers.addItem(item("Duplicate Layer", #selector(MainWindowController.duplicateLayer(_:)), "U", [.command, .control]))
        layers.addItem(item("Merge Layer Down", #selector(MainWindowController.mergeLayerDown(_:)), "M", [.command, .control]))
        layers.addItem(.separator())
        layers.addItem(item("Create/Release Clipping Mask", #selector(MainWindowController.toggleClippingMask(_:)),
                            "g", [.command, .option]))
        layers.addItem(item("Add Layer Mask", #selector(MainWindowController.addLayerMask(_:)), ""))
        layers.addItem(item("Apply Layer Mask", #selector(MainWindowController.applyLayerMask(_:)), ""))
        layers.addItem(item("Delete Layer Mask", #selector(MainWindowController.deleteLayerMask(_:)), ""))
        layers.addItem(.separator())
        layers.addItem(item("Group Layer", #selector(MainWindowController.groupLayer(_:)), "g", [.command]))
        layers.addItem(item("Ungroup", #selector(MainWindowController.ungroupLayer(_:)), "g", [.command, .shift]))
        layers.addItem(.separator())
        layers.addItem(item("Rotate / Zoom Layer\u{2026}", #selector(MainWindowController.rotateZoomLayer(_:)), "R", [.command, .control]))
        layers.addItem(item("Flip Layer Horizontal", #selector(MainWindowController.flipLayerHorizontal(_:)), ""))
        layers.addItem(item("Flip Layer Vertical", #selector(MainWindowController.flipLayerVertical(_:)), ""))
        layers.addItem(.separator())
        layers.addItem(item("Layer Properties…", #selector(MainWindowController.showLayerProperties), "F4", []))
        addSubmenu(layers, to: main)

        // Adjustments
        let adjustments = NSMenu(title: "Adjustments")
        adjustments.addItem(item("Auto-Level", #selector(MainWindowController.adjustAutoLevel(_:)), "L", [.command, .shift]))
        adjustments.addItem(item("Black and White", #selector(MainWindowController.adjustBlackAndWhite(_:)), "G", [.command, .shift]))
        adjustments.addItem(item("Brightness / Contrast…", #selector(MainWindowController.adjustBrightnessContrast(_:)), "C", [.command, .shift]))
        adjustments.addItem(item("Curves…", #selector(MainWindowController.adjustCurves(_:)), "M", [.command, .shift]))
        adjustments.addItem(item("Hue / Saturation…", #selector(MainWindowController.adjustHueSaturation(_:)), "U", [.command, .shift]))
        adjustments.addItem(item("Invert Colors", #selector(MainWindowController.adjustInvert(_:)), "I", [.command, .shift]))
        adjustments.addItem(item("Posterize…", #selector(MainWindowController.adjustPosterize(_:)), "P", [.command, .shift]))
        adjustments.addItem(item("Sepia", #selector(MainWindowController.adjustSepia(_:)), "E", [.command, .shift]))
        addSubmenu(adjustments, to: main)

        // Effects
        let effects = NSMenu(title: "Effects")
        let blurs = NSMenu(title: "Blurs")
        blurs.addItem(item("Gaussian Blur…", #selector(MainWindowController.effectGaussianBlur(_:)), ""))
        blurs.addItem(item("Motion Blur…", #selector(MainWindowController.effectMotionBlur(_:)), ""))
        let blursItem = NSMenuItem(title: "Blurs", action: nil, keyEquivalent: "")
        blursItem.submenu = blurs
        effects.addItem(blursItem)

        let distort = NSMenu(title: "Distort")
        distort.addItem(item("Bulge…", #selector(MainWindowController.effectBulge(_:)), ""))
        distort.addItem(item("Twist…", #selector(MainWindowController.effectTwist(_:)), ""))
        let distortItem = NSMenuItem(title: "Distort", action: nil, keyEquivalent: "")
        distortItem.submenu = distort
        effects.addItem(distortItem)

        let stylize = NSMenu(title: "Stylize")
        stylize.addItem(item("Edge Detect", #selector(MainWindowController.effectEdgeDetect(_:)), ""))
        stylize.addItem(item("Emboss", #selector(MainWindowController.effectEmboss(_:)), ""))
        stylize.addItem(item("Oil Painting…", #selector(MainWindowController.effectOilPainting(_:)), ""))
        stylize.addItem(item("Pixelate…", #selector(MainWindowController.effectPixelate(_:)), ""))
        let stylizeItem = NSMenuItem(title: "Stylize", action: nil, keyEquivalent: "")
        stylizeItem.submenu = stylize
        effects.addItem(stylizeItem)

        effects.addItem(.separator())
        effects.addItem(item("Add Noise…", #selector(MainWindowController.effectAddNoise(_:)), ""))
        effects.addItem(item("Glow…", #selector(MainWindowController.effectGlow(_:)), ""))
        effects.addItem(item("Sharpen…", #selector(MainWindowController.effectSharpen(_:)), ""))
        effects.addItem(item("Vignette…", #selector(MainWindowController.effectVignette(_:)), ""))
        addSubmenu(effects, to: main)

        // Window / Help
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""))
        let windowItem = addSubmenu(window, to: main)
        NSApp.windowsMenu = windowItem.submenu

        let help = NSMenu(title: "Help")
        help.addItem(item("Sketchy Help", #selector(showHelp), "?"))
        addSubmenu(help, to: main)

        NSApp.mainMenu = main
    }

    @discardableResult
    private func addSubmenu(_ menu: NSMenu, to main: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return item
    }

    /// The standard About panel, which picks up the icon and name from the
    /// bundle. Running unbundled there is no Info.plist, hence the fallbacks.
    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let copyright = info?["NSHumanReadableCopyright"] as? String
            ?? "© 2026 John Aquino · All rights reserved"

        let body = NSMutableParagraphStyle()
        body.alignment = .center
        body.lineSpacing = 2

        let credits = NSAttributedString(
            string: """
                Built by John Aquino

                A layered raster image editor for macOS, in the spirit of Paint.NET.
                Open source at github.com/johnaqu1no/Sketchy
                """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: body
            ])

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Sketchy",
            .applicationVersion: version,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright
        ])
    }

    @objc private func showShortcuts() {
        if shortcutsWindow == nil {
            shortcutsWindow = ShortcutsWindowController(shortcuts: hub.shortcuts)
        }
        shortcutsWindow?.showWindow(nil)
        shortcutsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Sketchy Help"
        alert.informativeText = """
        • Pick a tool from the Tools palette or press its shortcut key (B brush, P pencil, E eraser, \
        F fill, S select, W magic wand, T text, O shapes, K color picker, H pan, Z zoom).
        • Left-drag paints with the primary color, right-drag with the secondary color.
        • [ and ] change the brush size.
        • ⌘-scroll or pinch to zoom; the Pan tool or scrollbars move the canvas.
        • Layers, History and Colors live in the floating palettes (⌘1–⌘4).
        """
        alert.runModal()
    }
}
