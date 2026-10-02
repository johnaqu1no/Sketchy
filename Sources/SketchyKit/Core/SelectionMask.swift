import CoreGraphics
import CoreImage

/// The selection the way an edit sees it: the outline, and for a feathered
/// selection how much of each pixel is selected. A hard selection never
/// builds the coverage, so clipping to it stays a path clip.
final class SelectionMask {
    let path: CGPath
    /// How far the edge fades, in pixels. 0 is a hard edge.
    let feather: CGFloat
    let width: Int
    let height: Int

    init(path: CGPath, feather: CGFloat, width: Int, height: Int) {
        self.path = path
        self.feather = max(0, feather)
        self.width = width
        self.height = height
    }

    var isFeathered: Bool { feather > 0 }

    /// Grayscale coverage at canvas size, white where selected. Rows run
    /// top-down, the way a CGImage stores them.
    private(set) lazy var coverageImage: CGImage? = isFeathered ? makeCoverage() : nil

    /// The coverage bytes, for the per-pixel tools.
    private lazy var coverageBytes: [UInt8]? = {
        guard let image = coverageImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }()

    /// How much of the pixel at (x, y), canvas coordinates with the origin at
    /// the bottom left, is selected: 0 to 1.
    func amount(x: Int, y: Int) -> Float {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        guard let bytes = coverageBytes else {
            return path.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) ? 1 : 0
        }
        return Float(bytes[(height - 1 - y) * width + x]) / 255
    }

    /// Limits drawing on `ctx`, which is in canvas coordinates, to the
    /// selection, fading out over the feather.
    func clip(_ ctx: CGContext) {
        if let image = coverageImage {
            ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: image)
        } else {
            ctx.addPath(path)
            ctx.clip()
        }
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private func makeCoverage() -> CGImage? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(path)
        ctx.fillPath()
        guard let hard = ctx.makeImage() else { return nil }
        // The fade runs either side of the outline, the way Photoshop's does,
        // so the marching ants sit on the halfway line.
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let soft = CIImage(cgImage: hard)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(feather) / 2)
            .cropped(to: extent)
        guard let blurred = SelectionMask.ciContext.createCGImage(soft, from: extent, format: .L8,
                                                                  colorSpace: gray) else { return nil }
        return blurred
    }
}

extension CGPath {
    /// The outline grown outward by `distance` pixels, corners rounded.
    func expanded(by distance: CGFloat) -> CGPath {
        guard distance > 0 else { return self }
        let ring = copy(strokingWithWidth: distance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return union(ring)
    }

    /// The outline pulled inward by `distance` pixels.
    func contracted(by distance: CGFloat) -> CGPath {
        guard distance > 0 else { return self }
        let ring = copy(strokingWithWidth: distance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return subtracting(ring)
    }
}
