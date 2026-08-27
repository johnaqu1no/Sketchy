import AppKit
import CoreImage

/// The resampling kernels Core Graphics has no interpolation setting for.
///
/// `CGContext` covers nearest neighbour and its own interpolation ladder, but
/// not a windowed sinc or an honest area average — the two that matter at the
/// extremes, one for enlarging a small image and one for shrinking a large one
/// past the point where sampling four neighbours can represent what is there.
/// Both are done ahead of the draw, producing an image at the destination size
/// that is then blitted one-to-one.
enum Resampler {

    /// Renders `image` at `size` with `resampling`, or returns nil when the
    /// kernel does not apply and the caller should draw the image itself.
    static func scaled(_ image: CGImage, to size: CGSize, using resampling: Resampling) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard width != image.width || height != image.height else { return image }

        switch resampling {
        case .lanczos:
            return lanczos(image, width: width, height: height)
        case .boxAverage:
            // Averaging only means something when a destination pixel covers
            // more than one source pixel; enlarging takes the smooth path.
            guard width <= image.width, height <= image.height else { return nil }
            return boxAverage(image, width: width, height: height)
        case .pixels, .bilinear, .smooth:
            return nil
        }
    }

    /// Core Image's windowed-sinc scaler. `CILanczosScaleTransform` takes a
    /// uniform scale plus an aspect ratio, so a non-proportional resize is
    /// expressed as the vertical scale and the horizontal stretch on top.
    private static func lanczos(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let scale = CGFloat(height) / CGFloat(image.height)
        let aspect = (CGFloat(width) / CGFloat(image.width)) / max(scale, .leastNormalMagnitude)
        guard scale.isFinite, aspect.isFinite, scale > 0, aspect > 0,
              let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }

        // The filter's extent is the exact scaled rectangle, which rounds a
        // pixel out from the size that was asked for; the render is clamped to
        // the requested one so the result is the size the caller allocated.
        let rect = CGRect(x: output.extent.origin.x, y: output.extent.origin.y,
                          width: CGFloat(width), height: CGFloat(height))
        return sharedContext.createCGImage(output, from: rect)
    }

    /// A software renderer: the GPU path needs a display, and this runs in
    /// batch exports and in the headless self-test alike.
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: true,
                                                           .workingColorSpace: CGColorSpaceCreateDeviceRGB()])

    /// Area average. Each destination pixel takes the mean of the source
    /// pixels its footprint covers, weighted by how much of each it covers, so
    /// a reduction to a fraction of the original still sees every source pixel
    /// instead of the handful an interpolating kernel happens to land on.
    private static func boxAverage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let srcWidth = image.width
        let srcHeight = image.height
        let src = Layer.makeContext(width: srcWidth, height: srcHeight)
        src.draw(image, in: CGRect(x: 0, y: 0, width: srcWidth, height: srcHeight))
        guard let srcData = src.data else { return nil }
        let dst = Layer.makeContext(width: width, height: height)
        guard let dstData = dst.data else { return nil }

        let srcPixels = srcData.bindMemory(to: UInt8.self, capacity: src.bytesPerRow * srcHeight)
        let dstPixels = dstData.bindMemory(to: UInt8.self, capacity: dst.bytesPerRow * height)
        let xRatio = Double(srcWidth) / Double(width)
        let yRatio = Double(srcHeight) / Double(height)

        for y in 0..<height {
            let top = Double(y) * yRatio
            let bottom = min(Double(y + 1) * yRatio, Double(srcHeight))
            let firstRow = Int(top)
            let lastRow = max(firstRow, Int((bottom - 1e-9).rounded(.down)))
            for x in 0..<width {
                let left = Double(x) * xRatio
                let right = min(Double(x + 1) * xRatio, Double(srcWidth))
                let firstCol = Int(left)
                let lastCol = max(firstCol, Int((right - 1e-9).rounded(.down)))

                var sum = (b: 0.0, g: 0.0, r: 0.0, a: 0.0)
                var weightTotal = 0.0
                for row in firstRow...lastRow {
                    let rowWeight = min(Double(row + 1), bottom) - max(Double(row), top)
                    guard rowWeight > 0 else { continue }
                    let rowStart = row * src.bytesPerRow
                    for col in firstCol...lastCol {
                        let weight = rowWeight * (min(Double(col + 1), right) - max(Double(col), left))
                        guard weight > 0 else { continue }
                        let i = rowStart + col * 4
                        // Premultiplied BGRA, so the channels average directly:
                        // a transparent pixel contributes no colour of its own.
                        sum.b += Double(srcPixels[i]) * weight
                        sum.g += Double(srcPixels[i + 1]) * weight
                        sum.r += Double(srcPixels[i + 2]) * weight
                        sum.a += Double(srcPixels[i + 3]) * weight
                        weightTotal += weight
                    }
                }
                guard weightTotal > 0 else { continue }
                let o = y * dst.bytesPerRow + x * 4
                dstPixels[o]     = UInt8(min(255, (sum.b / weightTotal).rounded()))
                dstPixels[o + 1] = UInt8(min(255, (sum.g / weightTotal).rounded()))
                dstPixels[o + 2] = UInt8(min(255, (sum.r / weightTotal).rounded()))
                dstPixels[o + 3] = UInt8(min(255, (sum.a / weightTotal).rounded()))
            }
        }
        return dst.makeImage()
    }
}

extension Resampling {
    /// Draws `image` into `rect` the way this kernel wants it drawn: through
    /// Core Graphics for the interpolation settings it has, and through a
    /// pre-scaled copy for the ones it does not. The context's own
    /// interpolation setting is left as it was found.
    func draw(_ image: CGImage, in rect: CGRect, into ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if isCustomKernel,
           let scaled = Resampler.scaled(image, to: rect.size, using: self) {
            // The pixels already sit at the destination size; interpolating
            // them a second time would only soften what the kernel produced.
            ctx.interpolationQuality = .none
            ctx.draw(scaled, in: rect)
            return
        }
        ctx.interpolationQuality = quality
        ctx.draw(image, in: rect)
    }
}
