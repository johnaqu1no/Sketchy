import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Adjustments and Effects, applied to the active layer through Core Image.
enum ImageEffects {
    /// Filters run in sRGB rather than Core Image's default linear working space,
    /// so Invert and friends match what Paint.NET produces.
    private static let workingSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: workingSpace,
        .outputColorSpace: workingSpace
    ])

    static func apply(_ transform: (CIImage) -> CIImage?, to layer: Layer, selection: CGPath?) -> Bool {
        guard let src = layer.image else { return false }
        let input = CIImage(cgImage: src)
        guard let output = transform(input) else { return false }
        let rect = CGRect(x: 0, y: 0, width: layer.width, height: layer.height)
        guard let result = ciContext.createCGImage(output, from: rect,
                                                   format: .RGBA8, colorSpace: workingSpace) else { return false }
        let ctx = layer.context
        ctx.saveGState()
        if let selection { ctx.addPath(selection); ctx.clip() }
        ctx.setBlendMode(.copy)
        ctx.draw(result, in: rect)
        ctx.restoreGState()
        return true
    }

    // MARK: - Adjustments

    static func blackAndWhite(_ img: CIImage) -> CIImage? {
        let f = CIFilter.photoEffectMono(); f.inputImage = img; return f.outputImage
    }

    static func sepia(_ img: CIImage) -> CIImage? {
        let f = CIFilter.sepiaTone(); f.inputImage = img; f.intensity = 0.9; return f.outputImage
    }

    static func invert(_ img: CIImage) -> CIImage? {
        let f = CIFilter.colorInvert(); f.inputImage = img; return f.outputImage
    }

    static func brightnessContrast(_ img: CIImage, brightness: Double, contrast: Double) -> CIImage? {
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.brightness = Float(brightness)
        f.contrast = Float(contrast)
        return f.outputImage
    }

    static func hueSaturation(_ img: CIImage, hue: Double, saturation: Double) -> CIImage? {
        let controls = CIFilter.colorControls()
        controls.inputImage = img
        controls.saturation = Float(saturation)
        guard let sat = controls.outputImage else { return nil }
        let h = CIFilter.hueAdjust()
        h.inputImage = sat
        h.angle = Float(hue)
        return h.outputImage
    }

    static func autoLevels(_ img: CIImage) -> CIImage? {
        img.autoAdjustmentFilters(options: [.enhance: true, .redEye: false])
            .reduce(img) { partial, filter in
                filter.setValue(partial, forKey: kCIInputImageKey)
                return filter.outputImage ?? partial
            }
    }

    static func posterize(_ img: CIImage, levels: Double) -> CIImage? {
        let f = CIFilter.colorPosterize(); f.inputImage = img; f.levels = Float(levels); return f.outputImage
    }

    static func curves(_ img: CIImage, gamma: Double) -> CIImage? {
        let f = CIFilter.gammaAdjust(); f.inputImage = img; f.power = Float(gamma); return f.outputImage
    }

    // MARK: - Effects

    static func gaussianBlur(_ img: CIImage, radius: Double) -> CIImage? {
        let f = CIFilter.gaussianBlur(); f.inputImage = img.clampedToExtent(); f.radius = Float(radius)
        return f.outputImage?.cropped(to: img.extent)
    }

    static func motionBlur(_ img: CIImage, radius: Double, angle: Double) -> CIImage? {
        let f = CIFilter.motionBlur(); f.inputImage = img.clampedToExtent()
        f.radius = Float(radius); f.angle = Float(angle)
        return f.outputImage?.cropped(to: img.extent)
    }

    static func sharpen(_ img: CIImage, amount: Double) -> CIImage? {
        let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(amount); return f.outputImage
    }

    static func glow(_ img: CIImage, radius: Double) -> CIImage? {
        let f = CIFilter.bloom(); f.inputImage = img; f.radius = Float(radius); f.intensity = 0.8
        return f.outputImage?.cropped(to: img.extent)
    }

    static func pixelate(_ img: CIImage, scale: Double) -> CIImage? {
        let f = CIFilter.pixellate(); f.inputImage = img; f.scale = Float(scale)
        return f.outputImage?.cropped(to: img.extent)
    }

    static func emboss(_ img: CIImage) -> CIImage? {
        let f = CIFilter.convolution3X3()
        f.inputImage = img
        f.weights = CIVector(values: [-2, -1, 0, -1, 1, 1, 0, 1, 2], count: 9)
        f.bias = 0
        return f.outputImage?.cropped(to: img.extent)
    }

    static func edgeDetect(_ img: CIImage) -> CIImage? {
        let f = CIFilter.edges(); f.inputImage = img; f.intensity = 3
        return f.outputImage?.cropped(to: img.extent)
    }

    static func noise(_ img: CIImage, amount: Double) -> CIImage? {
        let noise = CIFilter.randomGenerator().outputImage?.cropped(to: img.extent)
        guard let noise else { return img }
        let blend = CIFilter.sourceOverCompositing()
        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = noise
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        blend.inputImage = alpha.outputImage
        blend.backgroundImage = img
        return blend.outputImage
    }

    static func oilPainting(_ img: CIImage, radius: Double) -> CIImage? {
        let f = CIFilter.crystallize(); f.inputImage = img; f.radius = Float(radius)
        return f.outputImage?.cropped(to: img.extent)
    }

    static func twist(_ img: CIImage, amount: Double) -> CIImage? {
        let f = CIFilter.twirlDistortion()
        f.inputImage = img
        f.center = CGPoint(x: img.extent.midX, y: img.extent.midY)
        f.radius = Float(min(img.extent.width, img.extent.height) / 2)
        f.angle = Float(amount)
        return f.outputImage?.cropped(to: img.extent)
    }

    static func bulge(_ img: CIImage, scale: Double) -> CIImage? {
        let f = CIFilter.bumpDistortion()
        f.inputImage = img
        f.center = CGPoint(x: img.extent.midX, y: img.extent.midY)
        f.radius = Float(min(img.extent.width, img.extent.height) / 2)
        f.scale = Float(scale)
        return f.outputImage?.cropped(to: img.extent)
    }

    static func vignette(_ img: CIImage, intensity: Double) -> CIImage? {
        let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(intensity); f.radius = 2
        return f.outputImage
    }
}
