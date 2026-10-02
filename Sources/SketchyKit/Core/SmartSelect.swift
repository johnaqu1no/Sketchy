import AppKit
import CoreGraphics
import CoreImage
import Vision

/// Selections Vision works out from the picture itself: the subject of a
/// photo, or the one object under the pointer. Each returns a mask over the
/// canvas for the caller to trace, or nil when Vision found nothing or the
/// Mac is too old to ask.
enum SmartSelect {
    /// Whether this Mac can find subjects at all. Vision's foreground masks
    /// arrived in macOS 14.
    static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Every foreground subject in `image`.
    static func subject(in image: CGImage) -> PixelOps.MaskedRegion? {
        guard #available(macOS 14.0, *) else { return nil }
        return foreground(in: image) { observation in observation.allInstances }
    }

    /// The single foreground object under `point`, canvas coordinates with
    /// the origin at the bottom left.
    static func object(in image: CGImage, at point: CGPoint) -> PixelOps.MaskedRegion? {
        guard #available(macOS 14.0, *) else { return nil }
        return foreground(in: image) { observation in
            // The instance mask labels each pixel with the object it belongs
            // to, 0 being background. It is smaller than the image, so the
            // point is scaled into it.
            let labels = observation.instanceMask
            CVPixelBufferLockBaseAddress(labels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
            let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels)
            guard let base = CVPixelBufferGetBaseAddress(labels) else { return [] }
            let row = CVPixelBufferGetBytesPerRow(labels)
            let x = Int(point.x / CGFloat(image.width) * CGFloat(w)).clamped(to: 0...(w - 1))
            let y = Int((1 - point.y / CGFloat(image.height)) * CGFloat(h)).clamped(to: 0...(h - 1))
            let label = Int(base.load(fromByteOffset: y * row + x, as: UInt8.self))
            return label == 0 ? [] : IndexSet(integer: label)
        }
    }

    @available(macOS 14.0, *)
    private static func foreground(in image: CGImage,
                                   instances pick: (VNInstanceMaskObservation) -> IndexSet)
        -> PixelOps.MaskedRegion? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        let chosen = pick(observation)
        guard !chosen.isEmpty,
              let scaled = try? observation.generateScaledMaskForImage(forInstances: chosen, from: handler)
        else { return nil }
        return region(from: scaled, width: image.width, height: image.height)
    }

    /// Turns Vision's mask, a float per pixel, into the half-way-or-more
    /// region the outline tracer reads.
    private static func region(from buffer: CVPixelBuffer, width: Int, height: Int) -> PixelOps.MaskedRegion? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height
        else { return nil }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let isFloat = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        var flags = [Bool](repeating: false, count: width * height)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for top in 0..<height {
            // Vision's rows run top-down; the canvas counts from the bottom.
            let y = height - 1 - top
            for x in 0..<width {
                let value: Float = isFloat
                    ? base.load(fromByteOffset: top * row + x * 4, as: Float.self)
                    : Float(base.load(fromByteOffset: top * row + x, as: UInt8.self)) / 255
                guard value >= 0.5 else { continue }
                flags[y * width + x] = true
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return PixelOps.MaskedRegion(flags: flags, bounds: CGRect(x: minX, y: minY,
                                                                  width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Every pixel of `layer` within `fuzziness` of `color`, anywhere on the
    /// canvas: Photoshop's Color Range. `invert` selects everything else.
    static func colorRange(in layer: Layer, color: NSColor, fuzziness: CGFloat,
                           invert: Bool = false) -> PixelOps.MaskedRegion? {
        guard let d = layer.pixels else { return nil }
        let w = layer.width, h = layer.height, stride = layer.bytesPerRow
        let c = color.srgb
        // Compared premultiplied, the way the buffer holds them.
        let alpha = c.alphaComponent
        let target = [Int((c.blueComponent * alpha * 255).rounded()), Int((c.greenComponent * alpha * 255).rounded()),
                      Int((c.redComponent * alpha * 255).rounded()), Int((alpha * 255).rounded())]
        let limit = Int((fuzziness.clamped(to: 0...1) * 255).rounded())
        var flags = [Bool](repeating: false, count: w * h)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        flags.withUnsafeMutableBufferPointer { buffer in
            guard let out = buffer.baseAddress else { return }
            for y in 0..<h {
                let rowStart = (h - 1 - y) * stride
                for x in 0..<w {
                    let o = rowStart + x * 4
                    let distance = max(max(abs(Int(d[o]) - target[0]), abs(Int(d[o + 1]) - target[1])),
                                       max(abs(Int(d[o + 2]) - target[2]), abs(Int(d[o + 3]) - target[3])))
                    guard (distance <= limit) != invert else { continue }
                    out[y * w + x] = true
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX else { return PixelOps.MaskedRegion(flags: flags, bounds: .zero) }
        return PixelOps.MaskedRegion(flags: flags, bounds: CGRect(x: minX, y: minY,
                                                                  width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
