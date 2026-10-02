import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// The image being edited: a stack of layers, a selection, and an undo history.
final class Document {
    private(set) var width: Int
    private(set) var height: Int
    var layers: [Layer] = []
    /// The active layer: the one tools paint on and the panels describe.
    /// Picking a different one drops any others picked alongside it.
    var selectedLayerIndex: Int = 0 {
        didSet {
            guard selectedLayerIndex != oldValue else { return }
            extraSelectedIDs = []
            maskTargeted = false
            showsMaskAlone = false
        }
    }
    /// Layers picked alongside the active one with ⇧ or ⌘ in the Layers
    /// palette. Commands that make sense on several layers at once (delete,
    /// duplicate, group, merge, drag) take all of them; painting still goes to
    /// the active layer alone.
    var extraSelectedIDs: Set<LayerID> = []
    /// Active selection in image coordinates; nil means "everything".
    var selectionPath: CGPath? {
        didSet { if selectionPath == nil { selectionFeather = 0 } }
    }
    /// How soft the selection's edge is, in pixels. A fresh selection starts
    /// hard; Feather Selection sets it.
    var selectionFeather: CGFloat = 0
    var fileURL: URL?
    var isDirty: Bool = false

    let history = HistoryManager()

    var onChange: (() -> Void)?
    var onStructureChange: (() -> Void)?
    /// Drawn straight after a layer while compositing. Floating pixels use it
    /// so a paste sits where its layer sits in the stack instead of on top of
    /// everything until it is dropped.
    var layerOverlay: ((Layer, CGContext) -> Void)?

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    var selectedLayer: Layer? {
        guard layers.indices.contains(selectedLayerIndex) else { return nil }
        return layers[selectedLayerIndex]
    }

    /// The layer a paint tool may touch: the active layer's mask when that is
    /// what is targeted, and otherwise the layer itself. A group holds layers,
    /// not pixels, so painting on one would go into a bitmap nothing ever
    /// draws; its mask can still be painted.
    var selectedRasterLayer: Layer? {
        guard let layer = selectedLayer else { return nil }
        if maskTargeted, let mask = layer.mask { return mask }
        return layer.isGroup ? nil : layer
    }

    /// Whether tools paint on the active layer's mask rather than its pixels.
    /// Picking another layer goes back to its pixels.
    var maskTargeted = false
    /// A paintbrush stroke still in progress on a mask, drawn into a copy of
    /// the mask while compositing so its effect shows before the mouse comes
    /// up, the way a stroke on pixels does.
    var maskStrokePreview: ((CGContext) -> Void)?

    /// What a mask looks like with any stroke in progress on it, as the
    /// grayscale image compositing clips with.
    private func liveMaskImage(_ mask: Layer) -> CGImage? {
        guard let preview = maskStrokePreview, mask === selectedRasterLayer else { return mask.maskImage }
        let scratch = Layer(width: mask.width, height: mask.height, name: "preview")
        if let pixels = mask.image { scratch.draw(image: pixels) }
        preview(scratch.context)
        return scratch.maskImage
    }

    /// Shows the active layer's mask on the canvas in place of the image,
    /// so what it hides can be seen and touched up.
    var showsMaskAlone = false

    /// Every picked layer, the active one included.
    var selectedLayerIDs: Set<LayerID> {
        var ids = extraSelectedIDs.intersection(layers.map(\.id))
        if let active = selectedLayer { ids.insert(active.id) }
        return ids
    }

    /// Picks the layers in `ids`, with the one at `active` as the layer tools
    /// paint on.
    func selectLayers(active: Int, ids: Set<LayerID>) {
        guard layers.indices.contains(active) else { return }
        selectedLayerIndex = active
        extraSelectedIDs = ids.subtracting([layers[active].id])
    }

    /// The picked layers as blocks to act on, bottom first. A layer inside a
    /// group that is itself picked rides along with the group rather than
    /// counting twice.
    var selectedRoots: [Int] {
        let ids = selectedLayerIDs
        return layers.indices.filter { index in
            guard ids.contains(layers[index].id) else { return false }
            var parent = parentGroup(of: index)
            while let p = parent {
                if ids.contains(layers[p].id) { return false }
                parent = parentGroup(of: p)
            }
            return true
        }
    }

    /// Whether this layer can be seen at all: hidden itself, or inside a
    /// hidden group, it cannot.
    func isEffectivelyVisible(_ index: Int) -> Bool {
        var current: Int? = index
        while let i = current {
            guard layers[i].isVisible else { return false }
            current = parentGroup(of: i)
        }
        return true
    }

    var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    init(width: Int, height: Int, background: NSColor? = .white) {
        self.width = max(1, width)
        self.height = max(1, height)
        let base = Layer(width: self.width, height: self.height, name: "Background")
        if let background { base.fill(with: background) }
        layers = [base]
        history.onTrim = { [weak self] dropped in
            guard let self else { return }
            appliedStep = max(0, appliedStep - dropped)
        }
        history.reset(with: snapshot(title: "Background"))
        markRecorded()
    }

    convenience init(image: CGImage, url: URL?) {
        self.init(width: image.width, height: image.height, background: nil)
        layers[0].draw(image: image)
        fileURL = url
        history.reset(with: snapshot(title: "Open"))
        markRecorded()
    }

    // MARK: - Snapshots / undo

    /// What each layer's pixels looked like when it was last recorded, so a
    /// step can say "unchanged" instead of copying the canvas again.
    private var recordedVersions: [LayerID: Int] = [:]

    func snapshot(title: String) -> HistorySnapshot {
        let previous = history.entries.indices.contains(history.cursor) ? history.cursor : nil
        let states = layers.map { layer -> HistorySnapshot.LayerState in
            .init(id: layer.id, name: layer.name, visible: layer.isVisible,
                  opacity: layer.opacity, blend: layer.blendMode,
                  pixels: pixelSource(for: layer, previousStep: previous),
                  kind: layer.kind, depth: layer.depth, collapsed: layer.isCollapsed,
                  maskID: layer.mask?.id, maskEnabled: layer.isMaskEnabled,
                  clipped: layer.clipsToBelow)
        }
        let masks = layers.compactMap(\.mask).map { mask -> HistorySnapshot.LayerState in
            .init(id: mask.id, name: mask.name, visible: true, opacity: 1, blend: .normal,
                  pixels: pixelSource(for: mask, previousStep: previous))
        }
        for layer in pixelHolders { recordedVersions[layer.id] = layer.contentVersion }
        return HistorySnapshot(title: title, layers: states, masks: masks,
                               selectedIndex: selectedLayerIndex, width: width, height: height,
                               selection: selectionPath, selectionFeather: selectionFeather)
    }

    /// The layers now match the newest step: the next edit is measured from
    /// here, so an untouched layer can be recorded as unchanged.
    private func markRecorded() {
        for layer in pixelHolders { layer.clearDirtyRegion() }
    }

    /// Every bitmap the document owns: the layers and their masks.
    private var pixelHolders: [Layer] { layers + layers.compactMap(\.mask) }

    /// Decides how little of a layer this step has to keep.
    private func pixelSource(for layer: Layer, previousStep: Int?) -> PixelSource {
        // A layer nothing has ever drawn into has no pixels to keep — and
        // asking it for an image would allocate the bitmap it has done without.
        guard layer.hasPixels else { return PixelSource(.whole(nil)) }
        // Nothing to inherit from: the step has to carry the pixels itself.
        guard let previousStep,
              history.entries[previousStep].pixelState(layer.id) != nil,
              history.entries[previousStep].width == width,
              history.entries[previousStep].height == height else {
            return PixelSource(.whole(layer.image))
        }
        if recordedVersions[layer.id] == layer.contentVersion {
            return PixelSource(.unchanged)
        }
        // Every so often the chain restarts with a full copy, so undo never
        // has to replay a long run of patches.
        guard history.patchDepth(forLayer: layer.id) < 12 else {
            return PixelSource(.whole(layer.image))
        }
        // A small edit keeps only its own rectangle. Past about a third of the
        // canvas the bookkeeping stops paying for itself.
        if let rect = layer.dirtyRegion, !rect.isEmpty,
           rect.width * rect.height * 3 < CGFloat(width * height),
           let full = layer.image,
           let patch = full.cropping(to: flipped(rect)) {
            return PixelSource(.patch(patch, rect))
        }
        return PixelSource(.whole(layer.image))
    }

    /// Image space has its origin at the top left; the canvas works bottom-up.
    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
    }

    func commit(_ title: String) {
        history.push(snapshot(title: title))
        appliedStep = history.cursor
        markRecorded()
        isDirty = true
        onChange?()
        // The palettes show the pixels too — a thumbnail is as stale after an
        // edit as the canvas is.
        onStructureChange?()
    }

    /// Which history step the layers currently hold, so stepping to another
    /// one can repaint just the difference.
    private var appliedStep: Int = 0

    func apply(_ snap: HistorySnapshot) {
        if applyByPatching(snap) { return }

        width = snap.width
        height = snap.height
        // Reuse the layer objects where the stack lines up: allocating a fresh
        // bitmap per layer per undo is the most expensive thing this could do.
        let existing = Dictionary(pixelHolders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func restored(_ id: LayerID, name: String, make: () -> Layer) -> Layer {
            let l: Layer
            if let reused = existing[id], reused.width == snap.width, reused.height == snap.height {
                l = reused
                l.clear()
            } else {
                l = make()
            }
            if let img = history.image(forLayer: id, at: history.cursor) { l.draw(image: img) }
            l.clearDirtyRegion()
            recordedVersions[id] = l.contentVersion
            return l
        }
        layers = snap.layers.map { st in
            let reused = existing[st.id]
            let l: Layer
            if let reused, reused.width == snap.width, reused.height == snap.height {
                l = reused
                l.clear()
            } else {
                l = Layer(width: snap.width, height: snap.height, name: st.name,
                          kind: st.kind, depth: st.depth, id: st.id)
            }
            apply(st, to: l)
            if let img = history.image(forLayer: st.id, at: history.cursor) { l.draw(image: img) }
            l.clearDirtyRegion()
            recordedVersions[st.id] = l.contentVersion
            l.mask = st.maskID.map { id in
                restored(id, name: st.name) {
                    let m = Layer(width: snap.width, height: snap.height, name: "\(st.name) mask", id: id)
                    m.isMask = true
                    return m
                }
            }
            return l
        }
        selectedLayerIndex = min(snap.selectedIndex, layers.count - 1)
        if selectedLayer?.mask == nil { maskTargeted = false; showsMaskAlone = false }
        selectionPath = snap.selection
        selectionFeather = snap.selectionFeather
        appliedStep = history.cursor
        isDirty = true
        onStructureChange?()
        onChange?()
    }

    private func apply(_ state: HistorySnapshot.LayerState, to layer: Layer) {
        layer.name = state.name
        layer.kind = state.kind
        layer.depth = state.depth
        layer.isVisible = state.visible
        layer.opacity = state.opacity
        layer.blendMode = state.blend
        layer.isCollapsed = state.collapsed
        layer.isMaskEnabled = state.maskEnabled
        layer.clipsToBelow = state.clipped
    }

    /// Steps to a neighbouring state by repainting only the rectangles that
    /// differ. Returns false when the two states are too far apart for that —
    /// a different stack, a different canvas size, a whole-layer copy — and
    /// the caller rebuilds instead.
    private func applyByPatching(_ snap: HistorySnapshot) -> Bool {
        let target = history.cursor
        guard target != appliedStep,
              history.entries.indices.contains(appliedStep),
              snap.width == width, snap.height == height,
              snap.layers.count == layers.count else { return false }

        // Masks have to line up too: one added or removed is a rebuild.
        for (state, layer) in zip(snap.layers, layers) where state.maskID != layer.mask?.id { return false }

        let holders = pixelHolders
        var regions: [CGRect] = []
        for holder in holders {
            guard snap.pixelState(holder.id) != nil,
                  let region = history.changedRegion(forLayer: holder.id, from: appliedStep, to: target)
            else { return false }
            regions.append(region)
        }
        for (state, layer) in zip(snap.layers, layers) {
            guard state.id == layer.id else { return false }
        }

        for (index, layer) in layers.enumerated() { apply(snap.layers[index], to: layer) }
        for (holder, changed) in zip(holders, regions) {
            let region = changed.integral.intersection(bounds)
            guard !region.isEmpty else { continue }
            guard let patch = history.image(forLayer: holder.id, at: target, in: region) else { return false }
            holder.edit(region) { ctx in
                ctx.clear(region)
                ctx.draw(patch, in: region)
            }
            holder.clearDirtyRegion()
            recordedVersions[holder.id] = holder.contentVersion
        }
        selectedLayerIndex = min(snap.selectedIndex, layers.count - 1)
        if selectedLayer?.mask == nil { maskTargeted = false; showsMaskAlone = false }
        selectionPath = snap.selection
        selectionFeather = snap.selectionFeather
        appliedStep = target
        isDirty = true
        onStructureChange?()
        onChange?()
        return true
    }

    @discardableResult func undo() -> Bool {
        guard let s = history.undo() else { return false }
        apply(s); return true
    }

    @discardableResult func redo() -> Bool {
        guard let s = history.redo() else { return false }
        apply(s); return true
    }

    func jumpHistory(to index: Int) {
        if let s = history.jump(to: index) { apply(s) }
    }

    // MARK: - Layer operations

    func addLayer(named name: String? = nil) {
        // Adding while a group is selected puts the layer inside it, which is
        // what the palette shows: the new row lands under the open folder.
        let host = selectedLayer
        let insideGroup = host?.isGroup == true
        let depth = host.map { $0.isGroup ? $0.depth + 1 : $0.depth } ?? 0
        let l = Layer(width: width, height: height,
                      name: name ?? "Layer \(layers.count + 1)", depth: depth)
        // Inside a group the new layer goes on top of its members, which is
        // the slot the header occupies; anywhere else it goes above the
        // selection.
        let at = insideGroup ? selectedLayerIndex : min(selectedLayerIndex + 1, layers.count)
        layers.insert(l, at: at)
        selectedLayerIndex = at
        commit("Add Layer")
        onStructureChange?()
    }

    /// Deletes every picked layer, groups with their contents.
    func deleteSelectedLayer() {
        let roots = selectedRoots
        guard !roots.isEmpty else { return }
        let doomed = Set(roots.flatMap { Array(subtreeRange(at: $0)) })
        // Something has to be left to paint on.
        guard layers.indices.contains(where: { !doomed.contains($0) && !layers[$0].isGroup }) else { return }
        let lowest = roots[0]
        for index in doomed.sorted(by: >) { layers.remove(at: index) }
        selectedLayerIndex = min(subtreeLowerBound(lowest, removing: doomed), layers.count - 1)
        extraSelectedIDs = []
        commit(roots.count > 1 ? "Delete Layers" : "Delete Layer")
        onStructureChange?()
    }

    /// Copies every picked layer, each copy just above its original, and picks
    /// the copies.
    func duplicateSelectedLayer() {
        let roots = selectedRoots
        guard !roots.isEmpty else { return }
        var copied: [LayerID] = []
        // Top first, so inserting above one block never moves the next.
        for root in roots.reversed() {
            let range = subtreeRange(at: root)
            let copies = layers[range].map { $0.copyLayer() }
            layers.insert(contentsOf: copies, at: range.upperBound)
            if let head = copies.last { copied.append(head.id) }
        }
        pick(copied)
        commit(roots.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
        onStructureChange?()
    }

    /// Where the block starting at `index` begins once `removed` is gone.
    private func subtreeLowerBound(_ index: Int, removing removed: Set<Int>) -> Int {
        let start = subtreeRange(at: index).lowerBound
        return start - removed.filter { $0 < start }.count
    }

    /// Picks the layers with these IDs, the top-most one active.
    private func pick(_ ids: [LayerID]) {
        let wanted = Set(ids)
        guard let top = layers.indices.last(where: { wanted.contains(layers[$0].id) }) else { return }
        selectLayers(active: top, ids: wanted)
    }

    /// Lifts the blocks rooted at `roots` out of the stack and puts them back
    /// together, in stack order, at `destination` (an insertion index in the
    /// current stack), renested at `depth`. Copies them instead when
    /// `copying`. Returns the IDs of the blocks' heads where they landed, or
    /// nil when the destination is inside one of the blocks being moved.
    @discardableResult
    private func relocate(_ roots: [Int], to destination: Int, depth: Int,
                          copying: Bool) -> [LayerID]? {
        let ranges = roots.map { subtreeRange(at: $0) }
        // A block cannot be dropped inside itself.
        guard !ranges.contains(where: { destination > $0.lowerBound && destination < $0.upperBound })
        else { return nil }
        var blocks: [[Layer]] = []
        for (root, range) in zip(roots, ranges) {
            let shift = depth - layers[root].depth
            let block = copying ? layers[range].map { $0.copyLayer() } : Array(layers[range])
            for layer in block { layer.depth = max(0, layer.depth + shift) }
            blocks.append(block)
        }
        var dest = destination
        if !copying {
            let moved = Set(ranges.flatMap { Array($0) })
            dest -= moved.filter { $0 < destination }.count
            for index in moved.sorted(by: >) { layers.remove(at: index) }
        }
        dest = dest.clamped(to: 0...layers.count)
        layers.insert(contentsOf: blocks.flatMap { $0 }, at: dest)
        // Clipping follows where a layer lands, as it does in Photoshop: in
        // the middle of a clipping stack it joins it, a clipped layer landing
        // on top of one stays in it, and anywhere else it is released rather
        // than clipping to whatever now happens to be below.
        for head in blocks.compactMap(\.last) {
            guard let index = layers.firstIndex(where: { $0 === head }) else { continue }
            guard let below = previousSibling(of: index) else { head.clipsToBelow = false; continue }
            let aboveClipped = nextSibling(of: index).map { layers[$0].clipsToBelow } ?? false
            head.clipsToBelow = aboveClipped || (head.clipsToBelow && layers[below].clipsToBelow)
        }
        return blocks.compactMap { $0.last?.id }
    }

    /// Moves, or copies, the picked layers to `destination` at `depth`. This is
    /// a drag in the Layers palette landing between two rows.
    func moveSelectedLayers(to destination: Int, depth: Int, copying: Bool = false) {
        guard let landed = relocate(selectedRoots, to: destination, depth: depth, copying: copying),
              !landed.isEmpty else { return }
        pick(landed)
        commit(copying ? (landed.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
                       : (landed.count > 1 ? "Reorder Layers" : "Reorder Layer"))
        onStructureChange?()
    }

    /// Drops the picked layers onto the row at `target`: into it when it is a
    /// group, and otherwise into a new group made around them and it.
    func dropSelectedLayers(onto target: Int, copying: Bool = false) {
        guard layers.indices.contains(target) else { return }
        let roots = selectedRoots
        let targetID = layers[target].id
        // Onto one of its own, or into its own contents, means nothing.
        for root in roots where subtreeRange(at: root).contains(target) { return }
        guard !roots.isEmpty else { return }

        if layers[target].isGroup {
            guard let landed = relocate(roots, to: target, depth: layers[target].depth + 1,
                                        copying: copying) else { return }
            pick(landed)
            commit(copying ? "Duplicate Layer" : "Reorder Layer")
            onStructureChange?()
            return
        }

        let hostDepth = layers[target].depth
        guard let landed = relocate(roots, to: target + 1, depth: hostDepth + 1,
                                    copying: copying),
              let host = layers.firstIndex(where: { $0.id == targetID }) else { return }
        layers[host].depth = hostDepth + 1
        let top = host + 1 + landed.reduce(0) { total, id in
            total + (layers.firstIndex(where: { $0.id == id }).map { subtreeRange(at: $0).count } ?? 0)
        }
        let header = Layer(width: width, height: height, name: nextGroupName(),
                           kind: .group, depth: hostDepth)
        layers.insert(header, at: top)
        selectedLayerIndex = top
        commit("Group Layers")
        onStructureChange?()
    }

    func mergeLayerDown() {
        guard layers.indices.contains(selectedLayerIndex) else { return }
        if selectedRoots.count > 1 {
            mergeSelectedLayers()
            return
        }
        if layers[selectedLayerIndex].isGroup {
            flattenGroup(at: selectedLayerIndex)
            return
        }
        let upper = layers[selectedLayerIndex]
        // Merging is only meaningful into a sibling that holds pixels.
        let belowIndex = selectedLayerIndex - 1
        guard belowIndex >= 0, !layers[belowIndex].isGroup,
              layers[belowIndex].depth == upper.depth else { return }
        let lower = layers[belowIndex]
        // A clipped layer only ever showed inside the one below, so merged
        // into it, it must not spill past that layer's edges.
        let shape = isClipped(selectedLayerIndex) ? lower.image : nil
        if let img = upper.image, upper.isVisible {
            lower.context.saveGState()
            if let mask = upper.activeMask?.maskImage { lower.context.clip(to: bounds, mask: mask) }
            lower.context.setAlpha(upper.opacity)
            lower.context.setBlendMode(upper.blendMode.cgBlendMode)
            lower.context.draw(img, in: bounds)
            lower.context.restoreGState()
        }
        if let shape {
            lower.context.saveGState()
            lower.context.setBlendMode(.destinationIn)
            lower.context.draw(shape, in: bounds)
            lower.context.restoreGState()
        }
        layers.remove(at: selectedLayerIndex)
        selectedLayerIndex = belowIndex
        commit("Merge Layer Down")
        onStructureChange?()
    }

    /// Moves the selection one slot within its own group, carrying a group's
    /// contents along with it.
    func moveSelected(up: Bool) {
        guard layers.indices.contains(selectedLayerIndex) else { return }
        let range = subtreeRange(at: selectedLayerIndex)
        let depth = layers[selectedLayerIndex].depth
        if up {
            let above = range.upperBound
            guard above < layers.count, layers[above].depth == depth else { return }
            moveSubtree(from: selectedLayerIndex, to: subtreeRange(at: above).upperBound, depth: depth)
        } else {
            var below = range.lowerBound - 1
            guard below >= 0, layers[below].depth >= depth else { return }
            // Step past a sibling group's members to reach its header.
            while below > 0, layers[below].depth > depth { below -= 1 }
            guard layers[below].depth == depth else { return }
            moveSubtree(from: selectedLayerIndex, to: subtreeRange(at: below).lowerBound, depth: depth)
        }
    }

    // MARK: - Layer masks

    /// Gives the active layer a mask and targets it, so the next stroke
    /// paints on the mask. With a selection, the mask shows just what is
    /// selected (or, with `hideAll`, hides just that), the way Photoshop's
    /// Add Mask does.
    func addLayerMask(hideAll: Bool = false) {
        guard let layer = selectedLayer, layer.mask == nil else { return }
        let mask = layer.makeMask(hideAll: selectionPath == nil ? hideAll : !hideAll)
        if selectionPath != nil {
            mask.context.saveGState()
            clipToSelection(mask.context)
            mask.context.setFillColor(hideAll ? NSColor.black.cgColor : NSColor.white.cgColor)
            mask.context.fill(bounds)
            mask.context.restoreGState()
        }
        layer.mask = mask
        layer.isMaskEnabled = true
        maskTargeted = true
        commit("Add Layer Mask")
        onStructureChange?()
    }

    /// Removes the active layer's mask, first baking it into the pixels when
    /// `apply` is set.
    func removeLayerMask(apply: Bool) {
        guard let layer = selectedLayer, let mask = layer.mask else { return }
        if apply, !layer.isGroup, let pixels = layer.image, let gray = mask.maskImage {
            layer.clear()
            layer.context.saveGState()
            layer.context.clip(to: bounds, mask: gray)
            layer.context.draw(pixels, in: bounds)
            layer.context.restoreGState()
        }
        layer.mask = nil
        maskTargeted = false
        showsMaskAlone = false
        commit(apply ? "Apply Layer Mask" : "Delete Layer Mask")
        onStructureChange?()
    }

    /// Turns the active layer's mask off or back on without losing it.
    func setLayerMaskEnabled(_ enabled: Bool) {
        guard let layer = selectedLayer, layer.mask != nil, layer.isMaskEnabled != enabled else { return }
        layer.isMaskEnabled = enabled
        commit(enabled ? "Enable Layer Mask" : "Disable Layer Mask")
        onStructureChange?()
    }

    /// Switches painting between the active layer's pixels and its mask.
    func targetMask(_ mask: Bool) {
        let wanted = mask && selectedLayer?.mask != nil
        guard wanted != maskTargeted else { return }
        maskTargeted = wanted
        if !wanted { showsMaskAlone = false }
        onStructureChange?()
        onChange?()
    }

    // MARK: - Groups

    /// The entries nested inside the group at `index`. Layers are stored
    /// bottom-first, so a group's members sit directly below its header —
    /// exactly where the palette draws them.
    func childRange(ofGroupAt index: Int) -> Range<Int> {
        guard layers.indices.contains(index), layers[index].isGroup else { return index..<index }
        let depth = layers[index].depth
        var lower = index
        while lower > 0, layers[lower - 1].depth > depth { lower -= 1 }
        return lower..<index
    }

    /// A layer and everything nested under it, as one movable block.
    func subtreeRange(at index: Int) -> Range<Int> {
        guard layers.indices.contains(index) else { return index..<index }
        return childRange(ofGroupAt: index).lowerBound..<(index + 1)
    }

    /// Index of the group holding `index`, if any.
    func parentGroup(of index: Int) -> Int? {
        guard layers.indices.contains(index) else { return nil }
        let depth = layers[index].depth
        guard depth > 0 else { return nil }
        var i = index + 1
        while i < layers.count {
            if layers[i].depth < depth { return layers[i].isGroup ? i : nil }
            i += 1
        }
        return nil
    }

    private func nextGroupName() -> String {
        "Group \(layers.filter(\.isGroup).count + 1)"
    }

    /// Moves a layer — with its contents when it is a group — to `destination`,
    /// an insertion index in the current stack, and renests it at `depth`.
    func moveSubtree(from index: Int, to destination: Int, depth newDepth: Int) {
        guard layers.indices.contains(index) else { return }
        let range = subtreeRange(at: index)
        // A group cannot be dropped inside itself.
        guard destination <= range.lowerBound || destination >= range.upperBound else { return }
        let moved = Array(layers[range])
        let shift = newDepth - layers[index].depth
        for l in moved { l.depth = max(0, l.depth + shift) }
        layers.removeSubrange(range)
        var dest = destination
        if dest > range.lowerBound { dest -= range.count }
        dest = dest.clamped(to: 0...layers.count)
        layers.insert(contentsOf: moved, at: dest)
        selectedLayerIndex = dest + moved.count - 1
        commit("Reorder Layer")
        onStructureChange?()
    }

    /// Dropping one layer onto another nests it: onto a group it joins that
    /// group, onto a plain layer a new group is made around the pair.
    func drop(subtreeAt index: Int, onto target: Int) {
        guard layers.indices.contains(index), layers.indices.contains(target), index != target else { return }
        let src = subtreeRange(at: index)
        guard !src.contains(target) else { return }

        if layers[target].isGroup {
            moveSubtree(from: index, to: target, depth: layers[target].depth + 1)
            return
        }

        let moved = Array(layers[src])
        let hostDepth = layers[target].depth
        let shift = hostDepth + 1 - layers[index].depth
        for l in moved { l.depth = max(0, l.depth + shift) }
        layers.removeSubrange(src)

        var t = target
        if t > src.lowerBound { t -= src.count }
        let host = layers[t]
        host.depth = hostDepth + 1
        let header = Layer(width: width, height: height, name: nextGroupName(),
                           kind: .group, depth: hostDepth)
        layers.insert(contentsOf: moved, at: t + 1)
        layers.insert(header, at: t + 1 + moved.count)
        selectedLayerIndex = t + 1 + moved.count
        commit("Group Layers")
        onStructureChange?()
    }

    /// Merges every picked layer into one, where the top-most of them sat,
    /// the way they look composited together.
    func mergeSelectedLayers() {
        let roots = selectedRoots
        guard roots.count > 1, let top = roots.last else { return }
        let buffer = Layer.makeContext(width: width, height: height)
        for root in roots {
            drawStack(subtreeRange(at: root), depth: layers[root].depth, into: buffer)
        }
        let merged = Layer(width: width, height: height, name: layers[top].name, depth: layers[top].depth)
        if let img = buffer.makeImage() { merged.draw(image: img) }
        let doomed = Set(roots.flatMap { Array(subtreeRange(at: $0)) })
        let at = subtreeLowerBound(top, removing: doomed)
        for index in doomed.sorted(by: >) { layers.remove(at: index) }
        layers.insert(merged, at: at)
        selectedLayerIndex = at
        extraSelectedIDs = []
        commit("Merge Layers")
        onStructureChange?()
    }

    /// Wraps the picked layers in a new group, where the top-most of them sat.
    func groupSelected() {
        guard layers.indices.contains(selectedLayerIndex) else { return }
        let roots = selectedRoots
        if roots.count > 1, let top = roots.last {
            let depth = layers[top].depth
            guard let landed = relocate(roots, to: subtreeRange(at: top).upperBound,
                                        depth: depth + 1, copying: false),
                  let head = landed.last,
                  let topIndex = layers.firstIndex(where: { $0.id == head }) else { return }
            let header = Layer(width: width, height: height, name: nextGroupName(),
                               kind: .group, depth: depth)
            layers.insert(header, at: topIndex + 1)
            selectedLayerIndex = topIndex + 1
            commit("Group Layers")
            onStructureChange?()
            return
        }
        let range = subtreeRange(at: selectedLayerIndex)
        let depth = layers[selectedLayerIndex].depth
        for l in layers[range] { l.depth += 1 }
        let header = Layer(width: width, height: height, name: nextGroupName(),
                           kind: .group, depth: depth)
        layers.insert(header, at: range.upperBound)
        selectedLayerIndex = range.upperBound
        commit("Group Layers")
        onStructureChange?()
    }

    /// Dissolves a group, leaving its members where they were.
    func ungroup(at index: Int) {
        guard layers.indices.contains(index), layers[index].isGroup else { return }
        let range = childRange(ofGroupAt: index)
        for l in layers[range] { l.depth = max(0, l.depth - 1) }
        layers.remove(at: index)
        selectedLayerIndex = min(max(0, range.upperBound - 1), layers.count - 1)
        commit("Ungroup")
        onStructureChange?()
    }

    /// Bakes a group down to a single raster layer.
    func flattenGroup(at index: Int) {
        guard layers.indices.contains(index), layers[index].isGroup else { return }
        let group = layers[index]
        let range = subtreeRange(at: index)
        let flat = Layer(width: width, height: height, name: group.name, depth: group.depth)
        flat.isVisible = group.isVisible
        flat.opacity = group.opacity
        flat.blendMode = group.blendMode
        let buffer = Layer.makeContext(width: width, height: height)
        drawStack(childRange(ofGroupAt: index), depth: group.depth + 1, into: buffer)
        if let img = buffer.makeImage() { flat.draw(image: img) }
        layers.replaceSubrange(range, with: [flat])
        selectedLayerIndex = min(range.lowerBound, layers.count - 1)
        commit("Merge Group")
        onStructureChange?()
    }

    func flatten() {
        guard layers.count > 1 else { return }
        let flat = Layer(width: width, height: height, name: "Background")
        if let img = composite() { flat.draw(image: img) }
        layers = [flat]
        selectedLayerIndex = 0
        commit("Flatten")
        onStructureChange?()
    }

    func moveLayer(from: Int, to: Int) {
        guard layers.indices.contains(from), to >= 0, to < layers.count, from != to else { return }
        let l = layers.remove(at: from)
        layers.insert(l, at: to)
        selectedLayerIndex = to
        commit("Reorder Layer")
        onStructureChange?()
    }

    // MARK: - Compositing

    /// The whole image as it exports: always the layers, never a mask being
    /// viewed on its own.
    func composite() -> CGImage? {
        composite(region: bounds, pixelSize: size, forDisplay: false)
    }

    /// Composites just `region` of the image into a buffer of `pixelSize`.
    /// The canvas only ever asks for what is on screen at the size it will be
    /// drawn, so a redraw costs screen pixels rather than canvas pixels — the
    /// difference between megabytes and gigabytes on a large document.
    func composite(region: CGRect, pixelSize: CGSize, forDisplay: Bool = true) -> CGImage? {
        let clipped = region.intersection(bounds)
        guard !clipped.isEmpty else { return nil }

        let pixelWidth = max(1, Int(pixelSize.width.rounded()))
        let pixelHeight = max(1, Int(pixelSize.height.rounded()))
        let ctx = Layer.makeContext(width: pixelWidth, height: pixelHeight)

        // Map the requested region onto the buffer.
        let scaleX = CGFloat(pixelWidth) / clipped.width
        let scaleY = CGFloat(pixelHeight) / clipped.height
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.translateBy(x: -clipped.minX, y: -clipped.minY)
        ctx.interpolationQuality = scaleX < 1 ? .medium : .none

        if forDisplay, showsMaskAlone, let mask = selectedLayer?.mask.flatMap(liveMaskImage) {
            ctx.draw(mask, in: bounds)
        } else {
            drawStack(layers.indices.startIndex..<layers.count, depth: 0, into: ctx)
        }
        return ctx.makeImage()
    }

    /// Composites one level of the stack. A group is drawn into a buffer of
    /// its own first so its opacity and blend mode apply to the result rather
    /// than to each member in turn — the whole point of grouping.
    func drawStack(_ range: Range<Int>, depth: Int, into ctx: CGContext) {
        for i in range where layers[i].depth == depth {
            // A clipped layer is drawn along with the layer it clips to.
            if layers[i].clipsToBelow, let below = previousSibling(of: i), range.contains(below) { continue }
            let run = clippedRun(above: i).filter { range.contains($0) }
            if run.isEmpty {
                drawLayer(at: i, depth: depth, into: ctx)
            } else {
                drawClippingStack(base: i, clipped: run, depth: depth, into: ctx)
            }
        }
    }

    /// Draws one entry of the stack, a group as a unit, with its mask.
    /// `opacity` and `blend` default to the layer's own.
    private func drawLayer(at i: Int, depth: Int, into ctx: CGContext,
                           opacity: CGFloat? = nil, blend: CGBlendMode? = nil) {
        let layer = layers[i]
        guard layer.isVisible, layer.opacity > 0 else { return }
        let img: CGImage?
        if layer.isGroup {
            let buffer = deviceBuffer(like: ctx)
            drawStack(childRange(ofGroupAt: i), depth: depth + 1, into: buffer)
            img = buffer.makeImage()
        } else {
            // Zoomed out, a pre-shrunk copy costs far less to sample than
            // the full-size layer.
            let scale = ctx.ctm.a
            img = layer.image(forScale: abs(scale))
        }
        guard let img else {
            layerOverlay?(layer, ctx)
            return
        }
        ctx.saveGState()
        if let mask = layer.activeMask.flatMap(liveMaskImage) { ctx.clip(to: bounds, mask: mask) }
        ctx.setAlpha(opacity ?? layer.opacity)
        ctx.setBlendMode(blend ?? layer.blendMode.cgBlendMode)
        if layer.isGroup {
            drawDevice(img, into: ctx)
        } else {
            ctx.draw(img, in: bounds)
        }
        ctx.restoreGState()
        layerOverlay?(layer, ctx)
    }

    /// A clipping stack: the base and the layers clipped to it are drawn
    /// together, then cut back to the base's own shape, and the result lands
    /// with the base's opacity and blend mode, the way Photoshop does it.
    private func drawClippingStack(base: Int, clipped: [Int], depth: Int, into ctx: CGContext) {
        let layer = layers[base]
        guard layer.isVisible, layer.opacity > 0 else { return }
        let buffer = deviceBuffer(like: ctx)
        drawLayer(at: base, depth: depth, into: buffer, opacity: 1, blend: .normal)
        guard let shape = buffer.makeImage() else { return }
        for index in clipped { drawLayer(at: index, depth: depth, into: buffer) }
        // Painting over the base can only change its colour, never its shape.
        buffer.saveGState()
        buffer.setBlendMode(.destinationIn)
        drawDevice(shape, into: buffer)
        buffer.restoreGState()
        guard let result = buffer.makeImage() else { return }
        ctx.saveGState()
        ctx.setAlpha(layer.opacity)
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        drawDevice(result, into: ctx)
        ctx.restoreGState()
    }

    /// A blank buffer the size of `ctx` in device pixels, drawing with the
    /// same transform, so a unit composited into it lands one-to-one.
    private func deviceBuffer(like ctx: CGContext) -> CGContext {
        let buffer = Layer.makeContext(width: ctx.width, height: ctx.height)
        buffer.concatenate(ctx.ctm)
        buffer.interpolationQuality = ctx.interpolationQuality
        return buffer
    }

    /// Draws a device-pixel buffer back one-to-one, dropping the transform so
    /// it is not scaled twice.
    private func drawDevice(_ image: CGImage, into ctx: CGContext) {
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.restoreGState()
    }

    // MARK: - Clipping masks

    /// The entry directly below `index` at the same level, skipping over a
    /// group's members to its header. Nil at the bottom of a group or stack.
    func previousSibling(of index: Int) -> Int? {
        guard layers.indices.contains(index) else { return nil }
        let below = subtreeRange(at: index).lowerBound - 1
        guard below >= 0, layers[below].depth == layers[index].depth else { return nil }
        return below
    }

    /// The entry directly above `index` at the same level, if any.
    func nextSibling(of index: Int) -> Int? {
        guard layers.indices.contains(index) else { return nil }
        let depth = layers[index].depth
        var above = index + 1
        while above < layers.count {
            if layers[above].depth < depth { return nil }
            if layers[above].depth == depth { return above }
            above += 1
        }
        return nil
    }

    /// The layers clipped to the one at `index`: the unbroken run of clipped
    /// siblings straight above it.
    func clippedRun(above index: Int) -> [Int] {
        guard layers.indices.contains(index), !isClipped(index) else { return [] }
        var run: [Int] = []
        var current = index
        while let next = nextSibling(of: current), layers[next].clipsToBelow {
            run.append(next)
            current = next
        }
        return run
    }

    /// Whether the layer at `index` is clipped: flagged, with something below
    /// it to clip to.
    func isClipped(_ index: Int) -> Bool {
        layers.indices.contains(index) && layers[index].clipsToBelow && previousSibling(of: index) != nil
    }

    /// The layer a clipped layer clips to.
    func clippingBase(of index: Int) -> Int? {
        guard isClipped(index) else { return nil }
        var current = index
        while let below = previousSibling(of: current) {
            if !layers[below].clipsToBelow { return below }
            current = below
        }
        return current == index ? nil : current
    }

    /// Clips the picked layers to the layer below them, or releases them.
    func setClipping(_ clipped: Bool) {
        let roots = selectedRoots.filter { clipped ? previousSibling(of: $0) != nil : layers[$0].clipsToBelow }
        guard !roots.isEmpty else { return }
        for root in roots { layers[root].clipsToBelow = clipped }
        commit(clipped ? "Create Clipping Mask" : "Release Clipping Mask")
        onStructureChange?()
    }

    /// Clips the layer at `index` to the one below, or releases it: an
    /// ⌥-click on the line between two rows.
    func toggleClipping(at index: Int) {
        guard layers.indices.contains(index) else { return }
        let clipping = !layers[index].clipsToBelow
        guard !clipping || previousSibling(of: index) != nil else { return }
        layers[index].clipsToBelow = clipping
        commit(clipping ? "Create Clipping Mask" : "Release Clipping Mask")
        onStructureChange?()
    }

    // MARK: - Canvas geometry

    /// Trims the canvas down to `box`, keeping history so the crop can be
    /// undone like any other edit.
    func crop(to box: CGRect) {
        let clipped = box.integral.intersection(bounds)
        guard !clipped.isEmpty else { return }
        let nw = max(1, Int(clipped.width))
        let nh = max(1, Int(clipped.height))
        layers = layers.map { old in
            old.reshaped(width: nw, height: nh) { img, ctx in
                ctx.draw(img, in: CGRect(x: -clipped.minX, y: -clipped.minY,
                                         width: CGFloat(old.width), height: CGFloat(old.height)))
            }
        }
        width = nw; height = nh
        selectionPath = nil
        commit("Crop to Selection")
        onStructureChange?()
    }

    func resizeCanvas(to newSize: CGSize, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let nw = max(1, Int(newSize.width.rounded()))
        let nh = max(1, Int(newSize.height.rounded()))
        let dx = (CGFloat(nw) - CGFloat(width)) * anchor.x
        let dy = (CGFloat(nh) - CGFloat(height)) * anchor.y
        layers = layers.map { old in
            old.reshaped(width: nw, height: nh) { img, ctx in
                ctx.draw(img, in: CGRect(x: dx, y: dy, width: CGFloat(old.width), height: CGFloat(old.height)))
            }
        }
        width = nw; height = nh
        selectionPath = nil
        commit("Canvas Size")
        onStructureChange?()
    }

    /// Resamples every layer. `fit` keeps the original proportions and places
    /// the scaled image with `anchor`, padding the rest with transparency;
    /// otherwise the image is stretched to the new size and the anchor is moot.
    func resizeImage(to newSize: CGSize,
                     anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
                     fit: Bool = false,
                     resampling: Resampling = .pixels) {
        let nw = max(1, Int(newSize.width.rounded()))
        let nh = max(1, Int(newSize.height.rounded()))

        var target = CGRect(x: 0, y: 0, width: nw, height: nh)
        if fit {
            let scale = min(CGFloat(nw) / CGFloat(width), CGFloat(nh) / CGFloat(height))
            let size = CGSize(width: (CGFloat(width) * scale).rounded(),
                              height: (CGFloat(height) * scale).rounded())
            target = CGRect(x: ((CGFloat(nw) - size.width) * anchor.x).rounded(),
                            y: ((CGFloat(nh) - size.height) * anchor.y).rounded(),
                            width: size.width, height: size.height)
        }

        layers = layers.map { old in
            old.reshaped(width: nw, height: nh) { img, ctx in
                // Resampling is a choice about this one draw, not a setting the
                // layer keeps for whatever a tool paints next.
                resampling.draw(img, in: target, into: ctx)
            }
        }
        width = nw; height = nh
        selectionPath = nil
        commit("Image Size")
        onStructureChange?()
    }

    /// Rotate the whole image by a multiple of 90 degrees (counter-clockwise turns).
    func rotate(turns: Int) {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return }
        let swap = (t % 2 == 1)
        let nw = swap ? height : width
        let nh = swap ? width : height
        layers = layers.map { old in
            old.reshaped(width: nw, height: nh) { img, ctx in
                // The transform has to be popped again: tools draw into this
                // context later and would inherit the rotation.
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
                ctx.rotate(by: CGFloat(t) * .pi / 2)
                ctx.draw(img, in: CGRect(x: -CGFloat(old.width) / 2, y: -CGFloat(old.height) / 2,
                                         width: CGFloat(old.width), height: CGFloat(old.height)))
                ctx.restoreGState()
            }
        }
        width = nw; height = nh
        selectionPath = nil
        commit("Rotate")
        onStructureChange?()
    }

    /// Free rotate / scale / pan of a single layer, resampled in place.
    func transformLayer(_ layer: Layer, angle: CGFloat, scale: CGFloat, offset: CGPoint) {
        guard let img = layer.image else { return }
        layer.clear()
        let ctx = layer.context
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(layer.width) / 2 + offset.x, y: CGFloat(layer.height) / 2 + offset.y)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(img, in: CGRect(x: -CGFloat(layer.width) / 2, y: -CGFloat(layer.height) / 2,
                                 width: CGFloat(layer.width), height: CGFloat(layer.height)))
        ctx.restoreGState()
    }

    func flip(horizontal: Bool, layerOnly: Bool = false) {
        // A mask is flipped along with its layer, so it keeps covering the
        // same pixels.
        let owners = layerOnly ? [selectedLayer].compactMap { $0 } : layers
        let targets = owners.flatMap { owner in [owner.isGroup ? nil : owner, owner.mask].compactMap { $0 } }
        for old in targets {
            guard let img = old.image else { continue }
            old.clear()
            old.context.saveGState()
            if horizontal {
                old.context.translateBy(x: CGFloat(old.width), y: 0)
                old.context.scaleBy(x: -1, y: 1)
            } else {
                old.context.translateBy(x: 0, y: CGFloat(old.height))
                old.context.scaleBy(x: 1, y: -1)
            }
            old.context.draw(img, in: CGRect(x: 0, y: 0, width: old.width, height: old.height))
            old.context.restoreGState()
        }
        commit(horizontal ? "Flip Horizontal" : "Flip Vertical")
    }

    // MARK: - Selection helpers

    /// Clears the selected region on the active layer — or the whole layer when
    /// nothing is selected. Returns false when there was nothing to erase.
    @discardableResult
    func eraseSelection() -> Bool {
        guard let layer = selectedRasterLayer else { return false }
        layer.context.saveGState()
        clipToSelection(layer.context)
        layer.context.clear(bounds)
        layer.context.restoreGState()
        commit(selectionPath == nil ? "Erase Layer" : "Erase Selection")
        return true
    }

    /// How big pasted pixels are drawn.
    enum PasteScale {
        /// Every pixel one for one, wherever the paste lands.
        case actualSize
        /// Stretched to the whole canvas, proportions and all.
        case stretchToCanvas
        /// Scaled to touch the canvas on its tighter axis, keeping its
        /// proportions, and centred on the slack one.
        case fitToCanvas

        /// Where an image of `imageSize` is drawn on a canvas of `canvas`.
        /// `corner` is only consulted at actual size: the other two are about
        /// the canvas, so where the paste would otherwise have landed is moot.
        func destination(imageSize: CGSize, canvas: CGSize, corner: CGPoint) -> CGRect {
            switch self {
            case .actualSize:
                return CGRect(origin: corner, size: imageSize)
            case .stretchToCanvas:
                return CGRect(origin: .zero, size: canvas)
            case .fitToCanvas:
                guard imageSize.width > 0, imageSize.height > 0 else {
                    return CGRect(origin: .zero, size: canvas)
                }
                let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
                let size = CGSize(width: (imageSize.width * scale).rounded(),
                                  height: (imageSize.height * scale).rounded())
                return CGRect(x: ((canvas.width - size.width) / 2).rounded(),
                              y: ((canvas.height - size.height) / 2).rounded(),
                              width: size.width, height: size.height)
            }
        }
    }

    /// Draws an image into the active layer and selects what was pasted, so it
    /// can be dragged straight away. At actual size, and without an origin, it
    /// lands in the top-left corner, or at the top-left of the current
    /// selection when there is one; the canvas-relative scales ignore both.
    /// `resampling` only matters to a scale that resizes the pixels.
    /// Where an actual-size paste lands when nothing says otherwise: the
    /// top-left of the selection if there is one, and the top-left of the
    /// canvas if there is not.
    func pasteCorner(for size: CGSize) -> CGPoint {
        guard let box = selectionPath?.boundingBoxOfPath else {
            return CGPoint(x: 0, y: CGFloat(height) - size.height)
        }
        return CGPoint(x: box.minX, y: box.maxY - size.height)
    }

    @discardableResult
    func paste(_ image: CGImage, at origin: CGPoint? = nil,
               scale: PasteScale = .actualSize,
               resampling: Resampling = .smooth) -> CGRect? {
        guard let layer = selectedRasterLayer else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        let corner = origin ?? pasteCorner(for: size)

        let destination = scale.destination(imageSize: size, canvas: self.size, corner: corner)
        layer.markEdited(destination)
        // Pixels landing at their own size are copied as they are: smoothing
        // there would soften every edge for nothing. A scale that resizes them
        // has to resample, and takes the setting for it.
        let unscaled = destination.size == size
        if unscaled {
            layer.rawContext.saveGState()
            layer.rawContext.interpolationQuality = .none
            layer.rawContext.draw(image, in: destination)
            layer.rawContext.restoreGState()
        } else {
            resampling.draw(image, in: destination, into: layer.rawContext)
        }
        // Anything hanging off the edge was clipped away, so the selection is
        // only over pixels that actually landed.
        let landed = destination.intersection(bounds)
        selectionPath = landed.isEmpty ? nil : CGPath(rect: landed, transform: nil)
        commit("Paste")
        return destination
    }

    // MARK: - Size limits

    /// Whether a canvas of a given size is something this Mac can work with.
    /// Layers are flat bitmaps, so the arithmetic is honest and worth checking
    /// before a document is created rather than crashing inside an allocation.
    enum SizeVerdict: Equatable {
        case fine
        /// Allowed, but worth warning about first. Bytes are the working set.
        case heavy(bytes: Int)
        case tooLarge(reason: String)
    }

    /// Hard ceiling on a side. Beyond this a document is refused outright.
    static let maximumSide = 50_000
    /// Largest side that needs no warning. Past it the document still opens,
    /// but a flat bitmap of that size is heavy enough to say so first.
    static let comfortableSide = 15_000

    static func bytesNeeded(width: Int, height: Int, layers: Int = 1) -> Int {
        // Four bytes a pixel per layer, and one more canvas for compositing.
        width * height * 4 * (max(1, layers) + 1)
    }

    static func verdict(width: Int, height: Int, layers: Int = 1,
                        physicalMemory: Int = Int(ProcessInfo.processInfo.physicalMemory)) -> SizeVerdict {
        guard width > 0, height > 0 else {
            return .tooLarge(reason: "Width and height must be at least 1 pixel.")
        }
        guard width <= maximumSide, height <= maximumSide else {
            return .tooLarge(reason: "Each side can be at most \(maximumSide) pixels.")
        }

        let bytes = bytesNeeded(width: width, height: height, layers: layers)
        // Two fifths of the machine is where editing stops being viable: past
        // that the allocation itself is likely to fail, and a refusal beats a
        // crash however large the side limit is.
        if bytes > physicalMemory * 2 / 5 {
            let gigabytes = Double(bytes) / 1_000_000_000
            return .tooLarge(reason: String(format: "That needs about %.1f GB, more than this Mac can work with.",
                                            gigabytes))
        }
        // Either a side past what is comfortable, or a working set big enough
        // to crowd the machine, is worth a word first.
        if width > comfortableSide || height > comfortableSide || bytes > physicalMemory / 6 {
            return .heavy(bytes: bytes)
        }
        return .fine
    }

    func selectAll() {
        guard selectionPath?.boundingBoxOfPath != bounds || selectionFeather > 0 else { return }
        selectionPath = CGPath(rect: bounds, transform: nil)
        selectionFeather = 0
        commit("Select All")
        onChange?()
    }

    func deselect() {
        guard selectionPath != nil else { return }
        selectionPath = nil
        selectionFeather = 0
        commit("Deselect")
        onChange?()
    }

    func invertSelection() {
        guard let sel = selectionPath else { return }
        // A real subtraction, not the canvas with the outline laid over it:
        // that only reads as inverted under even-odd, and the next add or
        // subtract, which goes by winding, filled the hole straight back in.
        selectionPath = canonicalSelection(CGPath(rect: bounds, transform: nil).subtracting(sel))
        commit("Invert Selection")
        onChange?()
    }

    /// A selection outline as it is kept: clipped to the canvas and with no
    /// overlaps, so every fill rule reads it the same way. Nil when nothing is
    /// left, since an empty selection would quietly block every edit.
    func canonicalSelection(_ path: CGPath) -> CGPath? {
        let box = path.boundingBoxOfPath
        guard !box.isNull, !box.isEmpty, box.intersects(bounds) else { return nil }
        // Inside the canvas there is nothing to cut, and an unneeded boolean
        // pass only blurs whole-pixel edges with rounding.
        guard !bounds.contains(box) else { return path.snappedToPixels() }
        let kept = path.intersection(CGPath(rect: bounds, transform: nil)).snappedToPixels()
        let keptBox = kept.boundingBoxOfPath
        return keptBox.isNull || keptBox.isEmpty ? nil : kept
    }

    private var cachedMask: SelectionMask?

    /// The selection as edits apply it, soft edge and all. Built once per
    /// selection: a feathered one costs a blur of the whole canvas.
    var selectionMask: SelectionMask? {
        guard let path = selectionPath else { return nil }
        if let cached = cachedMask, cached.path === path, cached.feather == selectionFeather,
           cached.width == width, cached.height == height {
            return cached
        }
        let mask = SelectionMask(path: path, feather: selectionFeather, width: width, height: height)
        cachedMask = mask
        return mask
    }

    /// How far past its outline a feathered selection still reaches, in
    /// pixels. Two blur radii cover everything visible of the fade.
    var selectionReach: CGFloat { (selectionFeather * 2).rounded(.up) }

    /// Applies the current selection as a clip on a context (image coordinates).
    func clipToSelection(_ ctx: CGContext) {
        selectionMask?.clip(ctx)
    }

    // MARK: - Load selection

    /// Selects what a layer shows, or what its mask lets through, combined
    /// with the current selection by `mode`. A group selects everything in
    /// it, as composited.
    func loadSelection(fromLayerAt index: Int, mask: Bool, mode: SelectionMode = .replace) {
        guard layers.indices.contains(index) else { return }
        let layer = layers[index]
        let source: Layer
        if mask, let m = layer.mask {
            source = m
        } else if layer.isGroup {
            source = Layer(width: width, height: height, name: "group")
            drawStack(childRange(ofGroupAt: index), depth: layer.depth + 1, into: source.context)
        } else {
            source = layer
        }
        let region = PixelOps.solidRegion(in: source, luminance: mask && layer.mask != nil)
        let traced = region.map { PixelOps.path(from: $0.flags, width: width, height: height, bounds: $0.bounds) }
            ?? CGMutablePath()

        let combined: CGPath
        if let existing = selectionPath, mode != .replace {
            switch mode {
            case .union:     combined = existing.union(traced)
            case .exclude:   combined = existing.subtracting(traced)
            case .intersect: combined = existing.intersection(traced)
            case .xor:       combined = existing.symmetricDifference(traced)
            case .replace:   combined = traced
            }
        } else {
            combined = traced
        }
        let before = selectionPath
        let keptFeather = mode == .replace ? 0 : selectionFeather
        selectionPath = canonicalSelection(combined)
        if selectionPath != nil { selectionFeather = keptFeather }
        guard selectionPath != nil || before != nil else { return }
        commit(mask ? "Load Mask as Selection" : "Load Layer as Selection")
        onChange?()
    }

    // MARK: - Modify selection

    /// Softens the selection's edge over `radius` pixels.
    func featherSelection(by radius: CGFloat) {
        guard selectionPath != nil, radius > 0 else { return }
        // Feathering twice adds up the way two blurs do.
        selectionFeather = (selectionFeather * selectionFeather + radius * radius).squareRoot()
        commit("Feather Selection")
        onChange?()
    }

    /// Grows the selection outward by `distance` pixels.
    func expandSelection(by distance: CGFloat) {
        guard let sel = selectionPath, distance > 0 else { return }
        selectionPath = canonicalSelection(sel.expanded(by: distance))
        commit("Expand Selection")
        onChange?()
    }

    /// Shrinks the selection inward by `distance` pixels. Shrinking it away
    /// entirely leaves nothing selected.
    func contractSelection(by distance: CGFloat) {
        guard let sel = selectionPath, distance > 0 else { return }
        selectionPath = canonicalSelection(sel.contracted(by: distance))
        if selectionPath == nil { selectionFeather = 0 }
        commit("Contract Selection")
        onChange?()
    }

    // MARK: - IO

    // MARK: - Native .sketchy documents

    static let nativeExtension = "sketchy"
    /// Documents saved before the rename still open.
    static let legacyExtension = "ptd"

    static func isNative(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == nativeExtension || ext == legacyExtension
    }

    /// Sketchy's own layered format: a binary property list holding the layer
    /// stack, each layer's pixels stored as PNG. Files written before the app
    /// was renamed carry the .ptd extension and an older format marker; both
    /// still open.
    func writeNative(to url: URL) throws {
        var layerDicts: [[String: Any]] = []
        for layer in layers {
            var dict: [String: Any] = [
                "name": layer.name,
                "visible": layer.isVisible,
                "opacity": Double(layer.opacity),
                "blend": layer.blendMode.rawValue,
                "depth": layer.depth,
                "group": layer.isGroup,
                "collapsed": layer.isCollapsed,
                "clipped": layer.clipsToBelow
            ]
            if !layer.isGroup {
                guard let img = layer.image,
                      let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
                    throw DocumentError.encodeFailed
                }
                dict["png"] = png
            }
            if let mask = layer.mask {
                guard let gray = mask.maskImage,
                      let png = NSBitmapImageRep(cgImage: gray).representation(using: .png, properties: [:]) else {
                    throw DocumentError.encodeFailed
                }
                dict["mask"] = png
                dict["maskEnabled"] = layer.isMaskEnabled
            }
            layerDicts.append(dict)
        }
        let root: [String: Any] = [
            "format": "Sketchy Document",
            // Version 2 added layer groups and version 3 layer and clipping
            // masks; older files still open.
            "version": 3,
            "width": width,
            "height": height,
            "selectedLayer": selectedLayerIndex,
            "layers": layerDicts
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: url)
        fileURL = url
        isDirty = false
    }

    static func openNative(url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              ["Sketchy Document", "Painted Document"].contains(root["format"] as? String ?? ""),
              let width = root["width"] as? Int,
              let height = root["height"] as? Int,
              let layerDicts = root["layers"] as? [[String: Any]], !layerDicts.isEmpty else {
            throw DocumentError.decodeFailed
        }
        let doc = Document(width: width, height: height, background: nil)
        doc.layers = layerDicts.enumerated().map { index, dict in
            let layer = Layer(width: width, height: height,
                              name: dict["name"] as? String ?? "Layer \(index + 1)",
                              kind: (dict["group"] as? Bool ?? false) ? .group : .raster,
                              depth: dict["depth"] as? Int ?? 0)
            layer.isCollapsed = dict["collapsed"] as? Bool ?? false
            layer.clipsToBelow = dict["clipped"] as? Bool ?? false
            layer.isVisible = dict["visible"] as? Bool ?? true
            layer.opacity = CGFloat(dict["opacity"] as? Double ?? 1)
            layer.blendMode = LayerBlendMode(rawValue: dict["blend"] as? String ?? "") ?? .normal
            if let png = dict["png"] as? Data,
               let src = CGImageSourceCreateWithData(png as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                layer.draw(image: img)
            }
            if let png = dict["mask"] as? Data,
               let src = CGImageSourceCreateWithData(png as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let mask = layer.makeMask()
                mask.restore(from: img)
                layer.mask = mask
                layer.isMaskEnabled = dict["maskEnabled"] as? Bool ?? true
            }
            return layer
        }
        doc.selectedLayerIndex = min(root["selectedLayer"] as? Int ?? 0, doc.layers.count - 1)
        doc.fileURL = url
        doc.isDirty = false
        doc.history.reset(with: doc.snapshot(title: "Open"))
        doc.markRecorded()
        return doc
    }

    /// True when the document keeps its layers on disk instead of flattening.
    var isNativeFile: Bool {
        fileURL.map(Document.isNative) ?? false
    }

    func write(to url: URL) throws {
        if Document.isNative(url) {
            try writeNative(to: url)
            return
        }
        try writeFlat(to: url)
        fileURL = url
        isDirty = false
    }

    /// Writes the composited image to `url`, picking the format from its
    /// extension. This is what saving to a flat format does, and what Export
    /// does — except that exporting leaves `fileURL` and the dirty flag alone,
    /// so the document still belongs to whatever file it came from.
    func export(to url: URL) throws {
        try writeFlat(to: url)
    }

    /// Every visible layer merged down and encoded. A hidden layer is left out,
    /// the same as it is on screen.
    private func writeFlat(to url: URL) throws {
        guard let img = composite() else { throw DocumentError.encodeFailed }
        let rep = NSBitmapImageRep(cgImage: img)
        rep.size = NSSize(width: width, height: height)
        let type: NSBitmapImageRep.FileType
        var props: [NSBitmapImageRep.PropertyKey: Any] = [:]
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            type = .jpeg
            props[.compressionFactor] = 0.92
        case "tiff", "tif": type = .tiff
        case "bmp":         type = .bmp
        case "gif":         type = .gif
        default:            type = .png
        }
        guard let data = rep.representation(using: type, properties: props) else {
            throw DocumentError.encodeFailed
        }
        try data.write(to: url)
    }

    static func open(url: URL) throws -> Document {
        if Document.isNative(url) {
            return try openNative(url: url)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw DocumentError.decodeFailed
        }
        if case .tooLarge(let reason) = verdict(width: img.width, height: img.height) {
            throw DocumentError.tooLarge(reason)
        }
        return Document(image: img, url: url)
    }
}

extension CGPath {
    /// The same outline with coordinates a rounding error away from a whole
    /// pixel put back on it. Boolean operations leave edges at 79.9999999,
    /// which then reads as a fraction of a pixel everywhere it is measured.
    func snappedToPixels() -> CGPath {
        func snap(_ v: CGFloat) -> CGFloat {
            let r = v.rounded()
            return abs(v - r) < 1e-4 ? r : v
        }
        func snap(_ p: CGPoint) -> CGPoint { CGPoint(x: snap(p.x), y: snap(p.y)) }
        let out = CGMutablePath()
        applyWithBlock { element in
            let pts = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:         out.move(to: snap(pts[0]))
            case .addLineToPoint:      out.addLine(to: snap(pts[0]))
            case .addQuadCurveToPoint: out.addQuadCurve(to: snap(pts[1]), control: snap(pts[0]))
            case .addCurveToPoint:
                out.addCurve(to: snap(pts[2]), control1: snap(pts[0]), control2: snap(pts[1]))
            case .closeSubpath:        out.closeSubpath()
            @unknown default:          break
            }
        }
        return out.copy() ?? out
    }
}

enum DocumentError: Error, LocalizedError {
    case encodeFailed, decodeFailed
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .encodeFailed: return "Sketchy could not encode that image format."
        case .decodeFailed: return "Sketchy could not read that file."
        case .tooLarge(let reason): return "That image is too large to open. \(reason)"
        }
    }
}
