import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encoding an image to land inside a range of file sizes.
///
/// The usual export asks for a format and takes whatever number of bytes falls
/// out. This is the other direction: a range of bytes is the requirement, and
/// the encoder quality and the pixel dimensions are the two dials turned until
/// the result fits — the thing you want when an upload caps attachments at
/// 8 MB, or a sprite sheet has to stay above a floor to keep its detail.
enum FileSizeExport {

    /// The formats worth targeting a size with. Lossless ones only have
    /// dimensions to give, which the search accounts for.
    enum Format: String, CaseIterable {
        case jpeg = "JPEG"
        case heic = "HEIC"
        case png = "PNG"
        case tiff = "TIFF"

        var isLossy: Bool { self == .jpeg || self == .heic }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .png:  return "png"
            case .tiff: return "tiff"
            }
        }

        var contentType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return UTType("public.heic") ?? .jpeg
            case .png:  return .png
            case .tiff: return .tiff
            }
        }

        /// The format a file name implies, for pre-selecting the popup.
        static func forExtension(_ ext: String) -> Format? {
            allCases.first { $0.fileExtension == ext.lowercased() }
                ?? (ext.lowercased() == "jpeg" ? .jpeg : nil)
        }
    }

    /// Which dial the search is allowed to turn.
    enum Method: String, CaseIterable {
        /// Keep every pixel, vary the encoder quality. Lossless formats have
        /// no quality to vary, so this can only report what they weigh.
        case quality = "Quality Only"
        /// Keep the quality, scale the image down (or up) instead.
        case dimensions = "Dimensions Only"
        /// Spend quality first, down to a floor, and only then start shedding
        /// pixels. The default: a photograph survives compression further than
        /// it survives being shrunk.
        case qualityThenDimensions = "Quality, Then Dimensions"
    }

    /// A target range in bytes. `min` may be zero, which just means "no floor".
    struct Range {
        let minBytes: Int
        let maxBytes: Int

        init(minBytes: Int, maxBytes: Int) {
            self.minBytes = max(0, min(minBytes, maxBytes))
            self.maxBytes = max(1, maxBytes)
        }

        /// Reads a range given in kilobytes, as the sheet collects it.
        init(minKB: Double, maxKB: Double) {
            self.init(minBytes: Int(minKB * 1024), maxBytes: Int(maxKB * 1024))
        }

        func contains(_ bytes: Int) -> Bool { bytes >= minBytes && bytes <= maxBytes }
    }

    /// What the search settled on.
    struct Result {
        let data: Data
        let pixelSize: CGSize
        /// The encoder quality used, or nil for a lossless format.
        let quality: Double?
        let attempts: Int
        /// False when even the extremes of the search missed the range; the
        /// data is then the closest miss rather than nothing at all.
        let isInRange: Bool
        /// Set when the result missed, saying which way, for the UI to explain.
        let missedLow: Bool

        var byteCount: Int { data.count }

        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        }
    }

    /// The lowest quality the search will hand a lossy encoder before it
    /// starts shrinking instead. Below this, artefacts cost more than the
    /// pixels the shrink would have taken.
    static let qualityFloor = 0.2
    /// The smallest fraction of the original the search will scale to. Past
    /// this the image is unrecognisable, so a target it cannot meet without
    /// going further is reported as a miss instead.
    static let scaleFloor = 0.05

    // MARK: - Search

    /// Finds the largest encoding that still fits under `range.maxBytes`.
    ///
    /// Both dials only ever make a file bigger, so the two are laid end to end
    /// as a single dial from "smallest this method can produce" to "largest",
    /// and bisected. That is one monotonic search rather than a search inside a
    /// search, which keeps the number of encodes — the expensive part — to the
    /// bisection's depth.
    static func fit(_ image: CGImage,
                    format: Format,
                    range: Range,
                    method: Method,
                    resampling: Resampling = .smooth,
                    allowsEnlarging: Bool = false,
                    steps: Int = 12) -> Result? {
        var attempts = 0
        var cache: [Int: (data: Data, size: CGSize, quality: Double?)] = [:]

        func attempt(at position: Double) -> (data: Data, size: CGSize, quality: Double?)? {
            // Quantised so the bisection's repeated visits to a position cost
            // one encode rather than one per visit.
            let key = Int((position * 10_000).rounded())
            if let hit = cache[key] { return hit }
            let dial = settings(at: position, image: image, format: format,
                                method: method, allowsEnlarging: allowsEnlarging)
            guard let scaled = render(image, to: dial.size, using: resampling),
                  let data = FileSizeExport.encode(scaled, format: format, quality: dial.quality) else { return nil }
            attempts += 1
            let value = (data, dial.size, format.isLossy ? dial.quality : nil)
            cache[key] = value
            return value
        }

        guard let smallest = attempt(at: 0), let largest = attempt(at: 1) else { return nil }

        // The range may sit entirely outside what this method can produce, in
        // which case the nearest end is the honest answer.
        if smallest.data.count > range.maxBytes {
            return Result(data: smallest.data, pixelSize: smallest.size, quality: smallest.quality,
                          attempts: attempts, isInRange: false, missedLow: false)
        }
        if largest.data.count < range.minBytes {
            return Result(data: largest.data, pixelSize: largest.size, quality: largest.quality,
                          attempts: attempts, isInRange: false, missedLow: true)
        }

        var low = 0.0
        var high = 1.0
        var best = smallest
        for _ in 0..<max(1, steps) {
            let mid = (low + high) / 2
            guard let candidate = attempt(at: mid) else { break }
            if candidate.data.count <= range.maxBytes {
                best = candidate
                low = mid
                // Already inside the range: bigger would only walk toward the
                // ceiling for nothing.
                if candidate.data.count >= range.minBytes { break }
            } else {
                high = mid
            }
        }
        if largest.data.count <= range.maxBytes { best = largest }

        return Result(data: best.data, pixelSize: best.size, quality: best.quality,
                      attempts: attempts,
                      isInRange: range.contains(best.data.count),
                      missedLow: best.data.count < range.minBytes)
    }

    /// Maps a position on the search dial onto the quality and dimensions it
    /// stands for. 0 is the smallest file the method can make, 1 the largest.
    static func settings(at position: Double,
                         image: CGImage,
                         format: Format,
                         method: Method,
                         allowsEnlarging: Bool) -> (size: CGSize, quality: Double) {
        let t = min(1, max(0, position))
        let full = CGSize(width: image.width, height: image.height)
        let ceiling = allowsEnlarging ? 2.0 : 1.0

        func sized(_ scale: Double) -> CGSize {
            CGSize(width: max(1, (Double(image.width) * scale).rounded()),
                   height: max(1, (Double(image.height) * scale).rounded()))
        }

        // A lossless format has no quality dial, so every method it is given
        // becomes a search over dimensions.
        guard format.isLossy else {
            return (sized(scaleFloor + (ceiling - scaleFloor) * t), 1)
        }

        switch method {
        case .quality:
            return (full, qualityFloor + (1 - qualityFloor) * t)
        case .dimensions:
            return (sized(scaleFloor + (ceiling - scaleFloor) * t), 0.9)
        case .qualityThenDimensions:
            // The bottom half of the dial shrinks the image at the quality
            // floor; the top half restores quality at full size. Pixels are
            // only sacrificed once compression has nothing left to give.
            if t < 0.5 {
                let ramp = t / 0.5
                return (sized(scaleFloor + (1 - scaleFloor) * ramp), qualityFloor)
            }
            let ramp = (t - 0.5) / 0.5
            let scale = 1 + (ceiling - 1) * ramp
            return (sized(scale), qualityFloor + (1 - qualityFloor) * ramp)
        }
    }

    // MARK: - Pieces

    /// Scales through the chosen kernel, or returns the image untouched when
    /// it is already the size asked for.
    static func render(_ image: CGImage, to size: CGSize, using resampling: Resampling) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard width != image.width || height != image.height else { return image }
        if let custom = Resampler.scaled(image, to: size, using: resampling) { return custom }
        let ctx = Layer.makeContext(width: width, height: height)
        ctx.interpolationQuality = resampling.quality
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// One encode. `quality` is ignored by the lossless formats, which is why
    /// the search stops turning that dial for them.
    static func encode(_ image: CGImage, format: Format, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.contentType.identifier as CFString,
                                                          1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: min(1, max(0, quality))]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
