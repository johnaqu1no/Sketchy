import AppKit

enum ToolID: String, CaseIterable {
    case rectangleSelect, moveSelectedPixels
    case lassoSelect, moveSelection
    case ellipseSelect, zoom
    case magicWand, pan
    case paintBucket, gradient
    case paintbrush, eraser
    case pencil, colorPicker
    case cloneStamp, recolor
    case healingBrush, spotHealing
    case smudge, blurBrush, sharpenBrush
    case text, line
    case shapes
    case polygonLassoSelect

    var title: String {
        switch self {
        case .rectangleSelect:    return "Rectangle Select"
        case .moveSelectedPixels: return "Move Selected Pixels"
        case .lassoSelect:        return "Lasso Select"
        case .moveSelection:      return "Move Selection"
        case .ellipseSelect:      return "Ellipse Select"
        case .zoom:               return "Zoom"
        case .magicWand:          return "Magic Wand"
        case .pan:                return "Pan"
        case .paintBucket:        return "Paint Bucket"
        case .gradient:           return "Gradient"
        case .paintbrush:         return "Paintbrush"
        case .eraser:             return "Eraser"
        case .pencil:             return "Pencil"
        case .colorPicker:        return "Color Picker"
        case .cloneStamp:         return "Clone Stamp"
        case .healingBrush:       return "Healing Brush"
        case .spotHealing:        return "Spot Healing Brush"
        case .smudge:             return "Smudge"
        case .blurBrush:          return "Blur"
        case .sharpenBrush:       return "Sharpen"
        case .recolor:            return "Recolor"
        case .text:               return "Text"
        case .line:               return "Line / Curve"
        case .shapes:             return "Shapes"
        case .polygonLassoSelect: return "Polygon Lasso"
        }
    }

    /// Tools that paint with a round tip sized by the brush width, and so get
    /// a ring under the pointer showing what they are about to cover.
    var hasBrushTip: Bool {
        switch self {
        case .paintbrush, .eraser, .cloneStamp, .recolor,
             .healingBrush, .spotHealing,
             .smudge, .blurBrush, .sharpenBrush:
            return true
        default: return false
        }
    }

    /// Tools that change pixels, and so need a layer rather than a group.
    var editsPixels: Bool {
        switch self {
        case .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonLassoSelect, .magicWand,
             .moveSelection, .zoom, .pan, .colorPicker:
            return false
        default:
            return true
        }
    }

    /// SF Symbol used in the Tools palette.
    var symbol: String {
        switch self {
        case .rectangleSelect:    return "rectangle.dashed"
        case .moveSelectedPixels: return "arrow.up.and.down.and.arrow.left.and.right"
        case .lassoSelect:        return "lasso"
        case .moveSelection:      return "rectangle.dashed.and.paperclip"
        case .ellipseSelect:      return "circle.dashed"
        case .zoom:               return "magnifyingglass"
        case .magicWand:          return "wand.and.stars"
        case .pan:                return "hand.raised"
        case .paintBucket:        return "drop.fill"
        case .gradient:           return "square.righthalf.filled"
        case .paintbrush:         return "paintbrush.pointed"
        case .eraser:             return "eraser"
        case .pencil:             return "pencil"
        case .colorPicker:        return "eyedropper"
        case .cloneStamp:         return "doc.on.doc"
        case .healingBrush:       return "bandage"
        case .spotHealing:        return "bandage.fill"
        case .smudge:             return "hand.draw"
        case .blurBrush:          return "wind"
        case .sharpenBrush:       return "sparkles"
        case .recolor:            return "circle.lefthalf.filled"
        case .text:               return "textformat"
        case .line:               return "line.diagonal"
        case .shapes:             return "square.on.circle"
        case .polygonLassoSelect: return "hexagon"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .rectangleSelect:    return "s"
        case .moveSelectedPixels: return "m"
        case .lassoSelect:        return "s"
        case .moveSelection:      return "m"
        case .ellipseSelect:      return "s"
        case .zoom:               return "z"
        case .magicWand:          return "w"
        case .pan:                return "h"
        case .paintBucket:        return "f"
        case .gradient:           return "g"
        case .paintbrush:         return "b"
        case .eraser:             return "e"
        case .pencil:             return "p"
        case .colorPicker:        return "k"
        case .cloneStamp:         return "l"
        case .healingBrush:       return "j"
        case .spotHealing:        return "j"
        case .smudge:             return "u"
        case .blurBrush:          return "y"
        case .sharpenBrush:       return "y"
        case .recolor:            return "r"
        case .text:               return "t"
        case .line:               return "o"
        case .shapes:             return "o"
        case .polygonLassoSelect: return "s"
        }
    }

    var isSelectionTool: Bool {
        switch self {
        case .rectangleSelect, .ellipseSelect, .lassoSelect, .polygonLassoSelect, .magicWand: return true
        default: return false
        }
    }

    /// Order of the two-column palette, matching the reference layout.
    static let paletteOrder: [ToolID] = [
        .rectangleSelect, .moveSelectedPixels,
        .lassoSelect, .polygonLassoSelect, .moveSelection,
        .ellipseSelect, .zoom,
        .magicWand, .pan,
        .paintBucket, .gradient,
        .paintbrush, .eraser,
        .pencil, .colorPicker,
        .cloneStamp, .recolor,
        .healingBrush, .spotHealing,
        .smudge, .blurBrush,
        .sharpenBrush, .text,
        .line,
        .shapes
    ]
}

enum ShapeKind: String, CaseIterable {
    case rectangle = "Rectangle"
    case roundedRectangle = "Rounded Rectangle"
    case ellipse = "Ellipse"
    case diamond = "Diamond"
    case triangle = "Triangle"
    case rightTriangle = "Right Triangle"
    case pentagon = "Pentagon"
    case hexagon = "Hexagon"
    case star = "Star"
    case fivePointStar = "5-Point Star"
    case heart = "Heart"
    case arrow = "Arrow"
    case cloud = "Cloud"

    var symbol: String {
        switch self {
        case .rectangle:        return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .ellipse:          return "circle"
        case .diamond:          return "diamond"
        case .triangle:         return "triangle"
        case .rightTriangle:    return "triangle.righthalf.filled"
        case .pentagon:         return "pentagon"
        case .hexagon:          return "hexagon"
        case .star:             return "star"
        case .fivePointStar:    return "star.fill"
        case .heart:            return "heart"
        case .arrow:            return "arrowshape.right"
        case .cloud:            return "cloud"
        }
    }
}

enum DrawMode: Int, CaseIterable {
    case outline, fill, outlineAndFill
    var symbol: String {
        switch self {
        case .outline:        return "rectangle"
        case .fill:           return "rectangle.fill"
        case .outlineAndFill: return "rectangle.inset.filled"
        }
    }
    var title: String {
        switch self {
        case .outline:        return "Draw Shape Outline"
        case .fill:           return "Draw Filled Shape"
        case .outlineAndFill: return "Draw Filled Shape With Outline"
        }
    }
}

enum StrokeStyle: String, CaseIterable {
    case solid = "Solid"
    case dashed = "Dashed"
    case dotted = "Dotted"
    case dashDot = "Dash Dot"

    var pattern: [CGFloat]? {
        switch self {
        case .solid:   return nil
        case .dashed:  return [6, 4]
        case .dotted:  return [1, 3]
        case .dashDot: return [6, 3, 1, 3]
        }
    }
}

enum FillStyle: String, CaseIterable {
    case solidColor = "Solid Color"
    case none = "None"
    case horizontalLines = "Horizontal Lines"
    case verticalLines = "Vertical Lines"
    case diagonalLines = "Diagonal Lines"
    case checker = "Checkerboard"
}

enum GradientKind: String, CaseIterable {
    case linear = "Linear"
    case reflected = "Reflected"
    case radial = "Radial"
    case conical = "Conical"
}

/// How pixels are resampled when something is scaled.
enum Resampling: String, CaseIterable {
    /// Nearest neighbour: every source pixel stays a hard-edged block.
    case pixels = "Pixels"
    /// Straight four-tap interpolation. Softer than nearest neighbour without
    /// the ringing a wider kernel can leave on hard edges.
    case bilinear = "Bilinear"
    /// Core Graphics' best interpolation, the general-purpose choice for
    /// photographs.
    case smooth = "Smooth"
    /// Windowed-sinc resampling. The sharpest enlargement of the set, at the
    /// cost of a little overshoot either side of a hard edge.
    case lanczos = "Lanczos"
    /// Every destination pixel is the average of the source pixels it covers.
    /// Nothing is skipped, so a big reduction keeps detail an interpolating
    /// filter drops; on an enlargement it falls back to smooth.
    case boxAverage = "Box Average"

    /// What Core Graphics is asked for when the draw goes through it. The
    /// kernels it has no setting for still name their closest neighbour, since
    /// that is what a fallback draw should use.
    var quality: CGInterpolationQuality {
        switch self {
        case .pixels:     return .none
        case .bilinear:   return .low
        case .smooth:     return .high
        case .lanczos:    return .high
        case .boxAverage: return .medium
        }
    }

    /// True for the kernels Sketchy resamples itself, which have to run over
    /// the image before it is drawn rather than during the draw.
    var isCustomKernel: Bool {
        self == .lanczos || self == .boxAverage
    }
}

/// What the recolor brush treats as the color to replace.
enum RecolorTarget: String, CaseIterable {
    /// The secondary color, as set in the palette.
    case secondaryColor = "Secondary Color"
    /// Whatever sits under the pointer when the stroke starts, so any color on
    /// the canvas can be targeted without loading it into the palette first.
    case sampledColor = "Color Under Cursor"
}

enum SelectionMode: String, CaseIterable {
    case replace = "Replace"
    case union = "Add (union)"
    case exclude = "Subtract"
    case intersect = "Intersect"
    case xor = "Xor"
}

/// Everything the options bar can tweak, shared by every tool.
final class ToolSettings {
    var tool: ToolID = .paintbrush
    var brushWidth: CGFloat = 4
    var hardness: CGFloat = 0.75
    var tolerance: CGFloat = 0.30
    var shape: ShapeKind = .rectangle
    var drawMode: DrawMode = .outlineAndFill
    var strokeStyle: StrokeStyle = .solid
    var fillStyle: FillStyle = .solidColor
    var gradientKind: GradientKind = .linear
    /// How opaque a gradient lands, so it can be layered over what is there.
    var gradientStrength: CGFloat = 1
    /// How hard smudge, blur and sharpen push, per dab.
    var brushStrength: CGFloat = 0.5
    var selectionMode: SelectionMode = .replace
    var blendMode: LayerBlendMode = .normal
    var antialiasing: Bool = true
    var fontName: String = "Helvetica"
    var fontSize: CGFloat = 24
    var bold = false, italic = false, underline = false
    var sampleMerged: Bool = false
    /// Pixel art is the common case for a canvas this size, so scaling keeps
    /// hard edges unless the user asks for smoothing.
    var resampling: Resampling = .pixels
    var fillGlobally: Bool = false
    /// The magic wand's own settings, kept apart from the paint bucket's and
    /// the color picker's so changing one does not quietly change the other.
    var wandGlobally: Bool = false
    var wandSampleMerged: Bool = false
    /// How many pixels across the wand averages to get the color it matches:
    /// 1, 3 or 5. More forgives noise in a photo.
    var wandSampleSize: Int = 1
    /// What the wand picks: pixels of a similar color, or the whole object
    /// under the click, found by Vision.
    var wandPicksObjects = false
    /// The last target-file-size export, so a second run of it opens on what
    /// the first one asked for rather than the defaults.
    var exportFormat: FileSizeExport.Format = .jpeg
    var exportMinKB: Double = 0
    var exportMaxKB: Double = 500
    var exportMethod: FileSizeExport.Method = .qualityThenDimensions
    var exportResampling: Resampling = .smooth
    /// Which color the recolor brush replaces.
    var recolorTarget: RecolorTarget = .secondaryColor

    /// What a scroll over the canvas changes for the current tool. The first
    /// option is the one the tool is mostly about; the second is for the
    /// tools that have a second dial worth reaching quickly.
    enum Adjustable {
        case size, hardness, tolerance, strength, brushStrength, fontSize
    }

    func adjustable(secondary: Bool) -> Adjustable? {
        switch tool {
        case .paintbrush:                 return secondary ? .hardness : .size
        case .eraser, .cloneStamp:        return secondary ? nil : .size
        case .healingBrush, .spotHealing: return secondary ? .hardness : .size
        case .smudge, .blurBrush,
             .sharpenBrush:               return secondary ? .brushStrength : .size
        case .recolor:                    return secondary ? .tolerance : .size
        case .paintBucket, .magicWand:    return secondary ? nil : .tolerance
        case .gradient:                   return secondary ? nil : .strength
        case .text:                       return secondary ? nil : .fontSize
        case .shapes, .line:              return secondary ? nil : .size
        default:                          return nil
        }
    }

    /// Nudges one option and reports it for the status bar. `steps` is whole
    /// wheel notches, positive for up.
    @discardableResult
    func adjust(_ option: Adjustable, steps: CGFloat) -> String {
        switch option {
        case .size:
            brushWidth = (brushWidth + steps).clamped(to: 1...200).rounded()
            return "Size \(Int(brushWidth))"
        case .hardness:
            hardness = (hardness + steps / 20).clamped(to: 0...1)
            return "Hardness \(Int(hardness * 100))%"
        case .tolerance:
            tolerance = (tolerance + steps / 100).clamped(to: 0...1)
            return "Tolerance \(Int(tolerance * 100))%"
        case .strength:
            gradientStrength = (gradientStrength + steps / 20).clamped(to: 0...1)
            return "Strength \(Int(gradientStrength * 100))%"
        case .brushStrength:
            brushStrength = (brushStrength + steps / 20).clamped(to: 0.05...1)
            return "Strength \(Int(brushStrength * 100))%"
        case .fontSize:
            fontSize = (fontSize + steps).clamped(to: 4...400).rounded()
            return "Font Size \(Int(fontSize))"
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
