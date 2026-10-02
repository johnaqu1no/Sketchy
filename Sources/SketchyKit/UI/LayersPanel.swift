import AppKit

/// Layer stack with visibility toggles, blend mode, opacity and the button bar.
final class LayersPanel: FloatingPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
    NSMenuDelegate {
    private let table = LayerTableView()
    private let blendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "100%")
    private(set) var buttonStrip: [NSButton] = []
    private let blendLabel = NSTextField(labelWithString: "Blend")
    /// What the button under the pointer does. The icons are small and a
    /// tooltip only shows up if the pointer sits still long enough; this says
    /// it straight away.
    private let hintLabel = NSTextField(labelWithString: "")
    private let opacityTitle = NSTextField(labelWithString: "Opacity")
    private var scroll: NSScrollView!
    /// The palette body. Held directly because `contentView` is swapped for an
    /// empty placeholder while the palette is docked in a rail.
    private var body: NSView!
    private weak var document: Document?
    /// Guards the reload → selection-changed → reload loop.
    private var isReloading = false
    /// Model indices in the order the table shows them.
    private(set) var visibleRows: [Int] = []
    /// The layer being renamed in place, if any.
    private var renamingIndex: Int?

    var onAdd: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onMerge: (() -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onProperties: (() -> Void)?
    var onGroup: (() -> Void)?
    var onUngroup: (() -> Void)?
    var onChange: (() -> Void)?
    /// Called just before the selected layer changes, so a pending edit can be
    /// put down while the layer it belongs to is still the selected one.
    var onBeforeSelect: (() -> Void)?

    init() {
        super.init(title: "Layers", size: NSSize(width: 262, height: 360))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 262, height: 360))

        scroll = NSScrollView(frame: NSRect(x: 0, y: 96, width: 262, height: 264))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let col = NSTableColumn(identifier: .init("layer"))
        col.width = 240
        col.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = LayerCellView.height
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.registerForDraggedTypes([.string])
        table.onEnter = { [weak self] in self?.beginRename() == true }
        // ⌥ while dragging copies instead of moving, as it does in Finder.
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        content.addSubview(scroll)

        blendLabel.font = .systemFont(ofSize: 11)
        content.addSubview(blendLabel)

        blendPopup.controlSize = .small
        blendPopup.font = .systemFont(ofSize: 11)
        blendPopup.addItems(withTitles: LayerBlendMode.allCases.map(\.rawValue))
        blendPopup.target = self
        blendPopup.action = #selector(blendChanged)
        content.addSubview(blendPopup)

        opacityTitle.font = .systemFont(ofSize: 11)
        content.addSubview(opacityTitle)

        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        content.addSubview(opacitySlider)

        opacityLabel.font = .systemFont(ofSize: 11)
        content.addSubview(opacityLabel)

        let specs: [(String, Selector, String)] = [
            ("plus.app", #selector(addTapped), "Add a new layer"),
            ("minus.square", #selector(deleteTapped), "Delete this layer"),
            ("plus.square.on.square", #selector(duplicateTapped), "Duplicate this layer"),
            ("square.stack.3d.down.right", #selector(mergeTapped), "Merge layer down"),
            ("arrow.up.square", #selector(upTapped), "Move layer up"),
            ("arrow.down.square", #selector(downTapped), "Move layer down"),
            ("folder.badge.plus", #selector(groupTapped), "Group layer"),
            ("folder.badge.minus", #selector(ungroupTapped), "Ungroup"),
            ("wrench.and.screwdriver", #selector(propertiesTapped), "Layer properties")
        ]
        for spec in specs {
            let b = HintingButton(image: NSImage.symbol(spec.0, spec.2),
                                  target: self, action: spec.1)
            b.isBordered = false
            b.toolTip = spec.2
            b.hint = spec.2
            b.onHint = { [weak self] text in self?.showHint(text) }
            content.addSubview(b)
            buttonStrip.append(b)
        }

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(hintLabel)
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentResized),
                                               name: NSView.frameDidChangeNotification, object: content)

        body = content
        contentView = content
        contentResized()
    }

    /// Lays the panel out for its current width: the button strip wraps, and the
    /// blend/opacity rows stack their labels once there is no room beside them.
    @objc private func contentResized() {
        guard let content = body else { return }
        let w = content.bounds.width
        let margin: CGFloat = 12
        let spacing: CGFloat = 34
        let perRow = max(1, Int((w - margin * 2 + 6) / spacing))
        let buttonRows = Int(ceil(Double(buttonStrip.count) / Double(perRow)))

        for (i, b) in buttonStrip.enumerated() {
            let row = buttonRows - 1 - (i / perRow), col = i % perRow
            b.frame = NSRect(x: margin + CGFloat(col) * spacing,
                             y: 19 + CGFloat(row) * 26, width: 28, height: 24)
        }

        hintLabel.frame = NSRect(x: margin, y: 3, width: max(40, w - margin * 2), height: 13)

        var y = 19 + CGFloat(buttonRows) * 26 + 4
        let stacked = w < 200
        let labelWidth: CGFloat = 56
        let controlX = stacked ? margin : margin + labelWidth + 6
        let controlWidth = max(40, w - controlX - margin - (stacked ? 0 : 46))

        if stacked {
            opacityTitle.frame = NSRect(x: margin, y: y + 20, width: labelWidth, height: 16)
            opacitySlider.frame = NSRect(x: margin, y: y, width: max(40, w - margin * 2 - 44), height: 20)
            opacityLabel.frame = NSRect(x: w - margin - 40, y: y + 2, width: 40, height: 16)
            y += 40
            blendLabel.frame = NSRect(x: margin, y: y + 22, width: labelWidth, height: 16)
            blendPopup.frame = NSRect(x: margin, y: y, width: max(60, w - margin * 2), height: 22)
            y += 44
        } else {
            opacityTitle.frame = NSRect(x: margin, y: y + 2, width: labelWidth, height: 16)
            opacitySlider.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 20)
            opacityLabel.frame = NSRect(x: w - margin - 42, y: y + 2, width: 42, height: 16)
            y += 26
            blendLabel.frame = NSRect(x: margin, y: y + 3, width: labelWidth, height: 16)
            blendPopup.frame = NSRect(x: controlX, y: y, width: max(60, w - controlX - margin), height: 22)
            y += 30
        }

        scroll.frame = NSRect(x: 0, y: y, width: w, height: max(40, content.bounds.height - y))
    }

    /// Selects a row as a click would, for tests.
    func selectRow(_ row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    /// Adds a row to the selection as a ⌘-click would, for tests.
    func extendSelection(toRow row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    /// What the hint line currently reads.
    var hintText: String { hintLabel.stringValue }

    /// Shows what the pointer is over, and clears it when the pointer leaves.
    private func showHint(_ text: String?) {
        hintLabel.stringValue = text ?? ""
    }

    func attach(_ doc: Document) {
        document = doc
        doc.onStructureChange = { [weak self] in self?.reload() }
        reload()
    }

    func reload() {
        isReloading = true
        defer { isReloading = false }
        rebuildRows()
        table.reloadData()
        guard let doc = document else { return }
        let picked = doc.selectedLayerIDs
        let rows = IndexSet(visibleRows.indices.filter {
            doc.layers.indices.contains(visibleRows[$0]) && picked.contains(doc.layers[visibleRows[$0]].id)
        })
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let l = doc.selectedLayer {
            blendPopup.selectItem(withTitle: l.blendMode.rawValue)
            opacitySlider.doubleValue = Double(l.opacity * 100)
            opacityLabel.stringValue = "\(Int(l.opacity * 100))%"
        }
    }

    /// Model indices in palette order, top-most first. A collapsed group hides
    /// its members, so the table is not simply the layer list reversed.
    private func rebuildRows() {
        guard let doc = document else { visibleRows = []; return }
        var out: [Int] = []
        var i = doc.layers.count - 1
        while i >= 0 {
            out.append(i)
            if doc.layers[i].isGroup, doc.layers[i].isCollapsed {
                i = doc.childRange(ofGroupAt: i).lowerBound - 1
            } else {
                i -= 1
            }
        }
        visibleRows = out
    }

    private func modelIndex(forRow row: Int) -> Int {
        visibleRows.indices.contains(row) ? visibleRows[row] : (document?.layers.count ?? 1) - 1
    }

    // MARK: - Actions

    @objc private func blendChanged() {
        guard let doc = document, let l = doc.selectedLayer,
              let mode = LayerBlendMode(rawValue: blendPopup.titleOfSelectedItem ?? "") else { return }
        l.blendMode = mode
        doc.commit("Layer Blend Mode")
        onChange?()
    }

    @objc private func opacityChanged() {
        guard let doc = document, let l = doc.selectedLayer else { return }
        l.opacity = CGFloat(opacitySlider.doubleValue / 100)
        opacityLabel.stringValue = "\(Int(opacitySlider.doubleValue))%"
        doc.onChange?()
        if NSApp.currentEvent?.type == .leftMouseUp { doc.commit("Layer Opacity") }
        onChange?()
    }

    @objc private func addTapped() { onAdd?() }
    @objc private func deleteTapped() { onDelete?() }
    @objc private func duplicateTapped() { onDuplicate?() }
    @objc private func mergeTapped() { onMerge?() }
    @objc private func upTapped() { onMoveUp?() }
    @objc private func downTapped() { onMoveDown?() }
    @objc private func groupTapped() { onGroup?() }
    @objc private func ungroupTapped() { onUngroup?() }
    @objc private func propertiesTapped() { onProperties?() }
    /// Double-clicking the name renames in place; anywhere else on the row
    /// opens the layer's properties.
    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCellView,
           let event = NSApp.currentEvent {
            let point = cell.convert(event.locationInWindow, from: nil)
            if point.x >= cell.label.frame.minX {
                selectRow(row)
                beginRename()
                return
            }
        }
        onProperties?()
    }

    // MARK: - Visibility

    /// Shows or hides the layers on `rows` as one step. Pressing an eye and
    /// dragging down the column comes through here once, at the end, with
    /// every row the pointer crossed.
    func setVisibility(rows: [Int], visible: Bool) {
        guard let doc = document else { return }
        let indices = rows.map(modelIndex(forRow:)).filter { doc.layers.indices.contains($0) }
        let changing = indices.filter { doc.layers[$0].isVisible != visible }
        guard !changing.isEmpty else { return }
        for index in changing { doc.layers[index].isVisible = visible }
        let plural = changing.count > 1 ? "Layers" : "Layer"
        doc.commit(visible ? "Show \(plural)" : "Hide \(plural)")
        reload()
        onChange?()
    }

    /// Follows the pointer down the eye column after a press, flipping each
    /// row it passes to match the first, and records it all as one step.
    fileprivate func beginEyeSwipe(fromRow row: Int) {
        guard let doc = document, let window = table.window else { return }
        let index = modelIndex(forRow: row)
        guard doc.layers.indices.contains(index) else { return }
        let visible = !doc.layers[index].isVisible
        var crossed: [Int] = []
        func touch(_ row: Int) {
            guard row >= 0, !crossed.contains(row) else { return }
            crossed.append(row)
            // Shown live, so the swipe can be watched; the step comes at the end.
            let model = modelIndex(forRow: row)
            guard doc.layers.indices.contains(model) else { return }
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCellView)?
                .showVisibility(visible)
        }
        touch(row)
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            touch(table.row(at: table.convert(event.locationInWindow, from: nil)))
            if event.type == .leftMouseUp { break }
        }
        setVisibility(rows: crossed, visible: visible)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let doc = document, table.clickedRow >= 0 else { return }
        // Right-clicking outside the selection acts on the row clicked, the
        // way Finder does.
        if !table.selectedRowIndexes.contains(table.clickedRow) { selectRow(table.clickedRow) }
        let several = doc.selectedRoots.count > 1
        let layer = doc.selectedLayer
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add(several ? "Duplicate Layers" : "Duplicate Layer", #selector(duplicateTapped))
        add("Rename…", #selector(renameFromMenu), enabled: !several)
        add(several ? "Delete Layers" : "Delete Layer", #selector(deleteTapped))
        menu.addItem(.separator())
        add(several ? "Group Layers" : "Group Layer", #selector(groupTapped))
        let inGroup = layer?.isGroup == true || doc.parentGroup(of: doc.selectedLayerIndex) != nil
        add("Ungroup", #selector(ungroupTapped), enabled: !several && inGroup)
        add(several ? "Merge Layers" : (layer?.isGroup == true ? "Merge Group" : "Merge Down"),
            #selector(mergeTapped))
        menu.addItem(.separator())
        let anyHidden = doc.selectedRoots.contains { !doc.layers[$0].isVisible }
        add(anyHidden ? "Show" : "Hide", #selector(toggleVisibilityFromMenu))
        add("Layer Properties…", #selector(propertiesTapped), enabled: !several)
    }

    @objc private func renameFromMenu() { beginRename() }

    @objc private func toggleVisibilityFromMenu() {
        guard let doc = document else { return }
        let roots = doc.selectedRoots
        let show = roots.contains { !doc.layers[$0].isVisible }
        setVisibility(rows: roots.compactMap { visibleRows.firstIndex(of: $0) }, visible: show)
    }

    // MARK: - Renaming

    /// Puts the selected row's name into an editable field, the way ⏎ renames
    /// a file in Finder. Typing goes to the field, so the single-letter tool
    /// shortcuts stay out of the way until it is committed. False when there is
    /// nothing to rename.
    @discardableResult
    func beginRename() -> Bool {
        guard let doc = document, let row = activeRow else { return false }
        let index = modelIndex(forRow: row)
        guard doc.layers.indices.contains(index) else { return false }
        renamingIndex = index
        // The cell may be off-screen in a scrolled table, in which case the
        // rename still stands and only the field is missing.
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerCellView)?
            .beginEditing(delegate: self)
        return true
    }

    /// Keeps `name` for the layer being renamed. False when the name is blank,
    /// unchanged, or nothing was being renamed — none of which is worth a step.
    @discardableResult
    func commitRename(_ name: String) -> Bool {
        let index = renamingIndex
        renamingIndex = nil
        closeEditor()
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = document, let index, doc.layers.indices.contains(index),
              !typed.isEmpty, typed != doc.layers[index].name else { reload(); return false }
        doc.layers[index].name = typed
        doc.commit("Rename Layer")
        reload()
        onChange?()
        return true
    }

    /// Abandons a rename in progress, leaving the name as it was.
    func cancelRename() {
        renamingIndex = nil
        closeEditor()
        reload()
    }

    /// Puts the editing row's label back to looking like a label.
    private func closeEditor() {
        guard let row = activeRow else { return }
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCellView)?
            .endEditing()
    }

    /// The row of the layer tools paint on, which is the one a rename names.
    private var activeRow: Int? {
        guard let doc = document else { return nil }
        return visibleRows.firstIndex(of: doc.selectedLayerIndex)
    }

    /// ⏎ or clicking away keeps the new name; ⎋ leaves it alone.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.cancel.rawValue
        if cancelled {
            cancelRename()
        } else {
            commitRename(field.stringValue)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        if visibleRows.isEmpty, document?.layers.isEmpty == false { rebuildRows() }
        return visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let doc = document else { return nil }
        let layer = doc.layers[modelIndex(forRow: row)]
        let index = modelIndex(forRow: row)
        let cell = LayerCellView()
        cell.apply(layer, subtitle: subtitle(for: index), dimmed: !doc.isEffectivelyVisible(index))
        cell.isActive = index == doc.selectedLayerIndex
        cell.toolTip = layer.name
        cell.visibility.onPress = { [weak self] in self?.beginEyeSwipe(fromRow: row) }
        cell.disclosure.tag = row
        cell.disclosure.target = self
        cell.disclosure.action = #selector(disclosureToggled(_:))
        return cell
    }

    /// The second line of a row: what kind of layer it is and anything set
    /// on it that the thumbnail cannot show.
    private func subtitle(for index: Int) -> String {
        guard let doc = document, doc.layers.indices.contains(index) else { return "" }
        let layer = doc.layers[index]
        var parts: [String] = []
        if layer.isGroup {
            let count = doc.childRange(ofGroupAt: index).filter { doc.layers[$0].depth == layer.depth + 1 }.count
            parts.append(count == 1 ? "1 layer" : "\(count) layers")
        }
        if layer.blendMode != .normal { parts.append(layer.blendMode.rawValue) }
        if layer.opacity < 1 { parts.append("\(Int((layer.opacity * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    @objc private func disclosureToggled(_ sender: NSButton) {
        guard let doc = document else { return }
        let index = modelIndex(forRow: sender.tag)
        guard doc.layers.indices.contains(index) else { return }
        doc.layers[index].isCollapsed.toggle()
        reload()
    }

    // MARK: - Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard draggedRow(from: info) != nil else { return [] }
        return info.draggingSourceOperationMask == .copy ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let from = draggedRow(from: info) else { return false }
        return drop(fromRow: from, toRow: row, onto: op == .on,
                    copying: info.draggingSourceOperationMask == .copy)
    }

    /// Lands a drag of `fromRow` — and every other picked row with it — on
    /// `toRow`: onto it when `onto`, otherwise in the gap above it.
    @discardableResult
    func drop(fromRow from: Int, toRow row: Int, onto: Bool, copying: Bool) -> Bool {
        guard let doc = document else { return false }
        let source = modelIndex(forRow: from)
        guard doc.layers.indices.contains(source) else { return false }
        // Dragging a row that was not picked drags that row alone.
        if !doc.selectedLayerIDs.contains(doc.layers[source].id) {
            doc.selectLayers(active: source, ids: [doc.layers[source].id])
        }

        if onto {
            // Dropping onto a row nests: into that group, or into a new one
            // made around them.
            doc.dropSelectedLayers(onto: modelIndex(forRow: row), copying: copying)
        } else {
            // A gap takes the nesting of the row it sits against.
            let neighbourRow = min(row, visibleRows.count - 1)
            guard visibleRows.indices.contains(neighbourRow) else { return false }
            let neighbour = visibleRows[neighbourRow]
            let destination = row < visibleRows.count
                ? doc.subtreeRange(at: neighbour).upperBound
                : doc.subtreeRange(at: neighbour).lowerBound
            doc.moveSelectedLayers(to: destination, depth: doc.layers[neighbour].depth, copying: copying)
        }
        reload()
        onChange?()
        return true
    }

    private func draggedRow(from info: NSDraggingInfo) -> Int? {
        guard let items = info.draggingPasteboard.pasteboardItems,
              let text = items.first?.string(forType: .string),
              let row = Int(text), visibleRows.indices.contains(row) else { return nil }
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let doc = document, !table.selectedRowIndexes.isEmpty else { return }
        let rows = table.selectedRowIndexes
        let ids = Set(rows.map(modelIndex(forRow:)).filter { doc.layers.indices.contains($0) }
            .map { doc.layers[$0].id })
        // The row just clicked becomes the one tools paint on. A ⌘-click that
        // took a row away leaves the active layer where it was if it is still
        // picked, and otherwise falls to the top-most row left.
        let activeRow: Int
        if table.clickedRow >= 0, rows.contains(table.clickedRow) {
            activeRow = table.clickedRow
        } else if let current = visibleRows.firstIndex(of: doc.selectedLayerIndex), rows.contains(current) {
            activeRow = current
        } else {
            activeRow = rows.first ?? table.selectedRow
        }
        let picked = modelIndex(forRow: activeRow)
        if picked != doc.selectedLayerIndex { onBeforeSelect?() }
        doc.selectLayers(active: picked, ids: ids)
        for row in rows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? LayerCellView)?
                .isActive = row == activeRow
        }
        if let l = doc.selectedLayer {
            blendPopup.selectItem(withTitle: l.blendMode.rawValue)
            opacitySlider.doubleValue = Double(l.opacity * 100)
            opacityLabel.stringValue = "\(Int(l.opacity * 100))%"
        }
        onChange?()
    }
}

/// A layer list that renames the selected row on ⏎, the way Finder does.
final class LayerTableView: NSTableView {
    /// Handles ⏎. Returns false when there was nothing to rename, so the key
    /// carries on to whatever else would have taken it.
    var onEnter: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, onEnter?() == true { return }
        super.keyDown(with: event)
    }
}

/// A button that says what it does while the pointer is over it, instead of
/// waiting on a tooltip that may never come.
final class HintingButton: NSButton {
    var hint: String?
    var onHint: ((String?) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHint?(hint) }
    override func mouseExited(with event: NSEvent) { onHint?(nil) }
}

/// The eye at the head of a row. A press hands over to the panel, which
/// follows the drag down the column so one swipe can hide a run of layers.
final class EyeButton: NSButton {
    var onPress: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onPress?() }
}

/// One row in the Layers table: eye, thumbnail, name and a line saying what
/// is set on the layer. Group rows are indented, show a folder, and fold their
/// contents away.
final class LayerCellView: NSTableCellView {
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let visibility = EyeButton(image: NSImage.symbol("eye", "Visible"), target: nil, action: nil)
    let disclosure = NSButton(image: NSImage.symbol("chevron.down", "Collapse"),
                              target: nil, action: nil)

    static let height: CGFloat = 44
    /// How far one level of nesting shifts a row.
    static let indent: CGFloat = 22
    /// Room the eye column takes at the left of every row.
    static let eyeWidth: CGFloat = 24

    /// Marks the layer tools paint on, which matters once several are picked.
    var isActive = false {
        didSet {
            thumb.layer?.borderColor = isActive
                ? NSColor.controlAccentColor.cgColor
                : NSColor(white: 0.35, alpha: 1).cgColor
            thumb.layer?.borderWidth = isActive ? 2 : (isGroupRow ? 0 : 1)
        }
    }
    private var isGroupRow = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: LayerCellView.height))
        visibility.isBordered = false
        visibility.imagePosition = .imageOnly
        visibility.frame = NSRect(x: 4, y: 12, width: 20, height: 20)
        addSubview(visibility)

        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        addSubview(disclosure)

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor(white: 0.35, alpha: 1).cgColor
        addSubview(thumb)

        label.font = .systemFont(ofSize: 12)
        label.autoresizingMask = [.width]
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label

        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.autoresizingMask = [.width]
        subtitle.lineBreakMode = .byTruncatingTail
        addSubview(subtitle)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Turns the name label into a live text field and hands it the keyboard.
    func beginEditing(delegate: NSTextFieldDelegate) {
        label.delegate = delegate
        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = true
        label.bezelStyle = .squareBezel
        label.drawsBackground = true
        window?.makeFirstResponder(label)
        label.currentEditor()?.selectAll(nil)
    }

    /// Puts the label back to looking like a label.
    func endEditing() {
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.delegate = nil
    }

    /// Draws the eye open or shut without touching the layer, for a swipe
    /// still in progress.
    func showVisibility(_ visible: Bool) {
        visibility.image = visible
            ? NSImage.symbol("eye", "Visible")
            : NSImage.symbol("eye.slash", "Hidden")
        visibility.contentTintColor = visible ? nil : .tertiaryLabelColor
    }

    /// `dimmed` fades a row that cannot be seen, whether hidden itself or
    /// inside a hidden group.
    func apply(_ layer: Layer, subtitle detail: String = "", dimmed: Bool = false) {
        isGroupRow = layer.isGroup
        let x = LayerCellView.eyeWidth + CGFloat(layer.depth) * LayerCellView.indent
        disclosure.isHidden = !layer.isGroup
        disclosure.frame = NSRect(x: x + 2, y: 14, width: 14, height: 16)
        disclosure.image = NSImage.symbol(layer.isCollapsed ? "chevron.right" : "chevron.down",
                                          layer.isCollapsed ? "Expand" : "Collapse")

        let thumbX = x + (layer.isGroup ? 18 : 4)
        thumb.frame = NSRect(x: thumbX, y: 5, width: 34, height: 34)
        thumb.layer?.borderWidth = layer.isGroup ? 0 : 1
        thumb.image = layer.isGroup
            ? NSImage.symbol("folder.fill", "Group")
            : layer.thumbnail(size: NSSize(width: 34, height: 34))

        let textX = thumbX + 42
        let textWidth = max(40, bounds.width - textX - 4)
        subtitle.stringValue = detail
        subtitle.isHidden = detail.isEmpty
        if detail.isEmpty {
            label.frame = NSRect(x: textX, y: 13, width: textWidth, height: 18)
        } else {
            label.frame = NSRect(x: textX, y: 21, width: textWidth, height: 17)
            subtitle.frame = NSRect(x: textX, y: 6, width: textWidth, height: 14)
        }
        label.stringValue = layer.name
        label.font = layer.isGroup ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        showVisibility(layer.isVisible)
        // The eye stays readable so a hidden row can be found and shown again.
        for view in [thumb, label, subtitle, disclosure] as [NSView] { view.alphaValue = dimmed ? 0.4 : 1 }
    }
}
