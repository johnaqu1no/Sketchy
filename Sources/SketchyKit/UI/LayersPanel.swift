import AppKit

/// Layer stack with visibility toggles, blend mode, opacity and the button bar.
final class LayersPanel: FloatingPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
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
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.registerForDraggedTypes([.string])
        table.onEnter = { [weak self] in self?.beginRename() == true }
        table.setDraggingSourceOperationMask(.move, forLocal: true)
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
        if let row = visibleRows.firstIndex(of: doc.selectedLayerIndex) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
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
    @objc private func doubleClicked() { onProperties?() }

    @objc fileprivate func visibilityToggled(_ sender: NSButton) {
        guard let doc = document else { return }
        let index = modelIndex(forRow: sender.tag)
        guard doc.layers.indices.contains(index) else { return }
        doc.layers[index].isVisible = (sender.state == .on)
        doc.onChange?()
        onChange?()
    }

    // MARK: - Renaming

    /// Puts the selected row's name into an editable field, the way ⏎ renames
    /// a file in Finder. Typing goes to the field, so the single-letter tool
    /// shortcuts stay out of the way until it is committed. False when there is
    /// nothing to rename.
    @discardableResult
    func beginRename() -> Bool {
        guard let doc = document, table.selectedRow >= 0 else { return false }
        let index = modelIndex(forRow: table.selectedRow)
        guard doc.layers.indices.contains(index) else { return false }
        renamingIndex = index
        // The cell may be off-screen in a scrolled table, in which case the
        // rename still stands and only the field is missing.
        (table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? LayerCellView)?
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
        guard table.selectedRow >= 0 else { return }
        (table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: false) as? LayerCellView)?
            .endEditing()
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
        let cell = LayerCellView()
        cell.apply(layer)
        cell.toolTip = layer.name
        cell.visibility.tag = row
        cell.visibility.target = self
        cell.visibility.action = #selector(visibilityToggled(_:))
        cell.disclosure.tag = row
        cell.disclosure.target = self
        cell.disclosure.action = #selector(disclosureToggled(_:))
        return cell
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
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let doc = document, let from = draggedRow(from: info) else { return false }
        let source = modelIndex(forRow: from)

        if op == .on {
            // Dropping onto a row nests: into that group, or into a new one
            // made around the pair.
            doc.drop(subtreeAt: source, onto: modelIndex(forRow: row))
        } else {
            // A gap takes the nesting of the row it sits against.
            let neighbourRow = min(row, visibleRows.count - 1)
            guard visibleRows.indices.contains(neighbourRow) else { return false }
            let neighbour = visibleRows[neighbourRow]
            let destination = row < visibleRows.count
                ? doc.subtreeRange(at: neighbour).upperBound
                : doc.subtreeRange(at: neighbour).lowerBound
            doc.moveSubtree(from: source, to: destination, depth: doc.layers[neighbour].depth)
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
        guard !isReloading, let doc = document, table.selectedRow >= 0 else { return }
        doc.selectedLayerIndex = modelIndex(forRow: table.selectedRow)
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

/// One row in the Layers table: thumbnail, name, visibility checkbox. Group
/// rows are indented, show a folder, and fold their contents away.
final class LayerCellView: NSTableCellView {
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    let visibility = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let disclosure = NSButton(image: NSImage.symbol("chevron.down", "Collapse"),
                              target: nil, action: nil)

    /// How far one level of nesting shifts a row.
    static let indent: CGFloat = 14

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
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
        addSubview(label)
        textField = label

        visibility.frame = NSRect(x: 212, y: 10, width: 20, height: 20)
        visibility.autoresizingMask = [.minXMargin]
        addSubview(visibility)
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

    func apply(_ layer: Layer) {
        let x = CGFloat(layer.depth) * LayerCellView.indent
        disclosure.isHidden = !layer.isGroup
        disclosure.frame = NSRect(x: x + 2, y: 12, width: 14, height: 16)
        disclosure.image = NSImage.symbol(layer.isCollapsed ? "chevron.right" : "chevron.down",
                                          layer.isCollapsed ? "Expand" : "Collapse")

        let thumbX = x + (layer.isGroup ? 18 : 4)
        thumb.frame = NSRect(x: thumbX, y: 3, width: 34, height: 34)
        thumb.layer?.borderWidth = layer.isGroup ? 0 : 1
        thumb.image = layer.isGroup
            ? NSImage.symbol("folder.fill", "Group")
            : layer.thumbnail(size: NSSize(width: 34, height: 34))

        label.frame = NSRect(x: thumbX + 42, y: 11, width: max(40, 206 - thumbX), height: 18)
        label.stringValue = layer.name
        label.font = layer.isGroup ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        visibility.state = layer.isVisible ? .on : .off
    }
}
