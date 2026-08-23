import AppKit
import CoreGraphics

/// Where a layer's pixels for one step come from. Steps share images: a layer
/// nothing touched points at the step before, and a small edit keeps only the
/// rectangle it changed. Whole-canvas copies per step are what made a large
/// document unusable after three brush strokes.
final class PixelSource {
    enum Content {
        case whole(CGImage?)
        /// The same pixels as the previous step for this layer.
        case unchanged
        /// The previous step with `patch` drawn at `rect`.
        case patch(CGImage, CGRect)
    }

    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    /// Roughly what this source costs, counting only what it owns.
    var bytes: Int {
        switch content {
        case .whole(let image): return (image?.width ?? 0) * (image?.height ?? 0) * 4
        case .unchanged:        return 0
        case .patch(let image, _): return image.width * image.height * 4
        }
    }
}

/// One undoable step: the layer stack, with pixels shared where they can be.
struct HistorySnapshot {
    struct LayerState {
        let id: LayerID
        let name: String
        let visible: Bool
        let opacity: CGFloat
        let blend: LayerBlendMode
        let pixels: PixelSource
        var kind: Layer.Kind = .raster
        var depth: Int = 0
        var collapsed: Bool = false
    }
    let title: String
    let layers: [LayerState]
    let selectedIndex: Int
    let width: Int
    let height: Int

    /// Roughly what this snapshot costs to keep.
    var bytes: Int { layers.reduce(0) { $0 + $1.pixels.bytes } }
}

final class HistoryManager {
    private(set) var entries: [HistorySnapshot] = []
    private(set) var cursor: Int = -1
    /// Cap so a long session doesn't eat all of RAM.
    var limit: Int = 60
    /// Snapshots are whole-canvas copies, so on a large document a handful of
    /// them outweighs the document itself. Total kept is capped at a share of
    /// the machine rather than a step count alone.
    var byteBudget: Int = Int(ProcessInfo.processInfo.physicalMemory) / 4

    /// Steps currently held, oldest first, and what they cost.
    var estimatedBytes: Int { entries.reduce(0) { $0 + $1.bytes } }

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < entries.count - 1 }
    var currentTitle: String? { cursor >= 0 ? entries[cursor].title : nil }

    var onChange: (() -> Void)?
    /// Reports how many steps were dropped off the front, so anything holding
    /// a step index can shift it.
    var onTrim: ((Int) -> Void)?

    /// Drops the oldest steps, first making sure the step that becomes the
    /// oldest carries its pixels outright: a patch whose base has been thrown
    /// away cannot be resolved.
    @discardableResult
    private func trimFront(_ count: Int) -> Int {
        let removable = min(count, max(0, entries.count - 1))
        guard removable > 0 else { return 0 }
        let survivor = removable
        var states: [HistorySnapshot.LayerState] = []
        for state in entries[survivor].layers {
            let resolved = image(forLayer: state.id, at: survivor)
            states.append(.init(id: state.id, name: state.name, visible: state.visible,
                                opacity: state.opacity, blend: state.blend,
                                pixels: PixelSource(.whole(resolved)),
                                kind: state.kind, depth: state.depth, collapsed: state.collapsed))
        }
        let old = entries[survivor]
        entries[survivor] = HistorySnapshot(title: old.title, layers: states,
                                            selectedIndex: old.selectedIndex,
                                            width: old.width, height: old.height)
        entries.removeFirst(removable)
        resolvedCache.removeAll()
        return removable
    }

    func reset(with snapshot: HistorySnapshot) {
        entries = [snapshot]
        cursor = 0
        resolvedCache.removeAll()
        onChange?()
    }

    func push(_ snapshot: HistorySnapshot) {
        if cursor < entries.count - 1 {
            entries.removeSubrange((cursor + 1)...)
        }
        entries.append(snapshot)
        var dropped = 0
        if entries.count > limit {
            dropped += trimFront(entries.count - limit)
        }
        // Drop the oldest steps until the total fits the budget, always
        // keeping the current state and one step to undo into.
        while entries.count > 2, estimatedBytes > byteBudget {
            dropped += trimFront(1)
        }
        cursor = entries.count - 1
        if dropped > 0 { onTrim?(dropped) }
        onChange?()
    }

    func undo() -> HistorySnapshot? {
        guard canUndo else { return nil }
        cursor -= 1
        onChange?()
        return entries[cursor]
    }

    func redo() -> HistorySnapshot? {
        guard canRedo else { return nil }
        cursor += 1
        onChange?()
        return entries[cursor]
    }

    func jump(to index: Int) -> HistorySnapshot? {
        guard index >= 0, index < entries.count else { return nil }
        cursor = index
        onChange?()
        return entries[cursor]
    }

    /// One resolved layer image, kept so stepping back and forth through
    /// history does not replay the same patches every time. Only the latest
    /// per layer is held: caching every step would put a full canvas copy in
    /// memory for each one, which is what deltas exist to avoid.
    private var resolvedCache: [LayerID: (index: Int, image: CGImage?)] = [:]

    /// The pixels for one layer of one step, replaying patches back to the
    /// last whole copy in a single buffer.
    func image(forLayer id: LayerID, at index: Int) -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        if let cached = resolvedCache[id], cached.index == index { return cached.image }

        // Walk back to the step that carries the pixels outright.
        var start = index
        var patches: [(CGImage, CGRect)] = []
        loop: while start >= 0 {
            guard let state = entries[start].layers.first(where: { $0.id == id }) else { break }
            switch state.pixels.content {
            case .whole:
                break loop
            case .unchanged:
                start -= 1
            case .patch(let patch, let rect):
                patches.append((patch, rect))
                start -= 1
            }
        }
        guard start >= 0,
              let base = entries[start].layers.first(where: { $0.id == id }),
              case .whole(let baseImage) = base.pixels.content else {
            return nil
        }

        var result = baseImage
        if !patches.isEmpty {
            let width = entries[index].width, height = entries[index].height
            let ctx = Layer.makeContext(width: width, height: height)
            if let baseImage { ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height)) }
            for (patch, rect) in patches.reversed() {
                ctx.clear(rect)
                ctx.draw(patch, in: rect)
            }
            result = ctx.makeImage()
        }
        resolvedCache[id] = (index, result)
        return result
    }

    /// The pixels of one layer, one step, limited to `rect`. Undo uses this to
    /// repaint only what an edit touched instead of the whole canvas.
    func image(forLayer id: LayerID, at index: Int, in rect: CGRect) -> CGImage? {
        guard entries.indices.contains(index) else { return nil }
        let box = rect.integral
        guard box.width >= 1, box.height >= 1 else { return nil }

        var start = index
        var patches: [(CGImage, CGRect)] = []
        loop: while start >= 0 {
            guard let state = entries[start].layers.first(where: { $0.id == id }) else { return nil }
            switch state.pixels.content {
            case .whole:      break loop
            case .unchanged:  start -= 1
            case .patch(let patch, let patchRect):
                patches.append((patch, patchRect))
                start -= 1
            }
        }
        guard start >= 0,
              let base = entries[start].layers.first(where: { $0.id == id }),
              case .whole(let baseImage) = base.pixels.content else { return nil }

        let ctx = Layer.makeContext(width: Int(box.width), height: Int(box.height))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        let canvas = CGRect(x: 0, y: 0, width: entries[index].width, height: entries[index].height)
        if let baseImage { ctx.draw(baseImage, in: canvas) }
        for (patch, patchRect) in patches.reversed() where patchRect.intersects(box) {
            ctx.clear(patchRect)
            ctx.draw(patch, in: patchRect)
        }
        return ctx.makeImage()
    }

    /// The region a layer's pixels differ over between two steps, or nil when
    /// the difference is not describable as patches — a resize, a whole copy,
    /// a layer that only exists on one side.
    /// Nil means the difference cannot be described as patches; an empty
    /// rectangle means the pixels are the same on both sides.
    func changedRegion(forLayer id: LayerID, from: Int, to: Int) -> CGRect? {
        guard entries.indices.contains(from), entries.indices.contains(to) else { return nil }
        guard entries[from].width == entries[to].width,
              entries[from].height == entries[to].height else { return nil }
        let lower = min(from, to), upper = max(from, to)
        guard lower != upper else { return .zero }

        var region: CGRect = .zero
        for index in (lower + 1)...upper {
            guard let state = entries[index].layers.first(where: { $0.id == id }) else { return nil }
            switch state.pixels.content {
            case .unchanged: continue
            case .patch(_, let rect): region = region.isEmpty ? rect : region.union(rect)
            case .whole: return nil
            }
        }
        return region
    }

    /// How many steps back the pixels for a layer are carried by patches. A
    /// chain that grows without bound makes undo slow, so the document plants
    /// a whole copy once in a while.
    func patchDepth(forLayer id: LayerID) -> Int {
        var depth = 0
        var index = cursor
        while index >= 0, let state = entries[index].layers.first(where: { $0.id == id }) {
            switch state.pixels.content {
            case .whole: return depth
            case .unchanged, .patch: depth += 1
            }
            index -= 1
        }
        return depth
    }
}
