// Extracted from MetalTerminalRenderer.swift
import Metal
import Foundation

extension MetalTerminalRenderer {

    // MARK: - CRT Effect

    /// Enable or disable CRT post-processing. Persists the preference in user defaults.
    func setCRTEffectEnabled(_ enabled: Bool) {
        crtConfiguration.isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CRTEffect.enabledDefaultsKey)
        if !enabled {
            hasCapturedPreviousFrame = false
        }
        isDirty = true
    }

    /// Apply custom CRT parameters.
    func setCRTEffectConfiguration(_ configuration: CRTEffectConfiguration) {
        crtConfiguration = configuration
        UserDefaults.standard.set(configuration.isEnabled, forKey: CRTEffect.enabledDefaultsKey)
        if !configuration.isEnabled {
            hasCapturedPreviousFrame = false
        }
        isDirty = true
    }

    /// Refresh CRT effect enabled state from persisted settings.
    func reloadCRTEffectSettings() {
        crtConfiguration.isEnabled = CRTEffect.loadEnabledFromDefaults()
        if !crtConfiguration.isEnabled {
            hasCapturedPreviousFrame = false
        }
        isDirty = true
    }

    // MARK: - Gradient Background Effect

    /// Enable or disable the gradient background effect.
    func setGradientBackgroundEnabled(_ enabled: Bool) {
        gradientConfiguration.isEnabled = enabled
        gradientConfiguration.save()
        isDirty = true
    }

    /// Apply a complete gradient background configuration.
    func setGradientBackgroundConfiguration(_ configuration: GradientBackgroundConfiguration) {
        gradientConfiguration = configuration
        gradientConfiguration.save()
        isDirty = true
    }

    /// Reload gradient background settings from persisted UserDefaults.
    func reloadGradientBackgroundSettings() {
        gradientConfiguration = GradientBackgroundConfiguration.load()
        isDirty = true
    }

    // MARK: - Scanner (Knight Rider) Effect

    /// Reload scanner effect settings from persisted UserDefaults.
    func reloadScannerEffectSettings() {
        scannerConfiguration = ScannerEffectConfiguration.load()
        isDirty = true
    }

    // MARK: - Bold Text Color

    /// Reload bold-text color settings from persisted UserDefaults.
    func reloadBoldTextColorSettings() {
        boldTextColorConfiguration = BoldTextColorConfiguration.load()
        isDirty = true
    }

    // MARK: - Bloom Effect

    /// Reload bloom effect settings from persisted UserDefaults.
    func reloadBloomEffectSettings() {
        bloomConfiguration = BloomEffectConfiguration.load()
        isDirty = true
    }

    // MARK: - Smooth Scroll

    /// Reload smooth scroll settings from persisted UserDefaults.
    func reloadSmoothScrollSettings() {
        smoothScrollConfiguration = SmoothScrollConfiguration.load()
        smoothScrollEngine.reloadConfiguration(smoothScrollConfiguration)
        isDirty = true
    }

    /// Ensure half-resolution bloom intermediate textures exist and match drawable size.
    func ensureBloomTextures(width: Int, height: Int) {
        let bw = max(1, width / 2)
        let bh = max(1, height / 2)

        if bloomBrightTexture?.width != bw || bloomBrightTexture?.height != bh {
            bloomBrightTexture = makeBloomHalfResTexture(width: bw, height: bh)
        }
        if bloomBlurH?.width != bw || bloomBlurH?.height != bh {
            bloomBlurH = makeBloomHalfResTexture(width: bw, height: bh)
        }
        if bloomBlurV?.width != bw || bloomBlurV?.height != bh {
            bloomBlurV = makeBloomHalfResTexture(width: bw, height: bh)
        }
    }

    private func makeBloomHalfResTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        descriptor.resourceOptions = .storageModePrivate
        return device.makeTexture(descriptor: descriptor)
    }

    /// Current gradient background configuration (read-only).
    var currentGradientConfiguration: GradientBackgroundConfiguration {
        gradientConfiguration
    }

    // MARK: - Solid Background Effect

    /// Enable or disable the solid background effect.
    func setSolidBackgroundEnabled(_ enabled: Bool) {
        solidBackgroundConfiguration.isEnabled = enabled
        solidBackgroundConfiguration.save()
        isDirty = true
    }

    /// Apply a complete solid background configuration.
    func setSolidBackgroundConfiguration(_ configuration: SolidBackgroundConfiguration) {
        solidBackgroundConfiguration = configuration
        solidBackgroundConfiguration.save()
        isDirty = true
    }

    /// Reload solid background settings from persisted UserDefaults.
    func reloadSolidBackgroundSettings() {
        solidBackgroundConfiguration = SolidBackgroundConfiguration.load()
        isDirty = true
    }

    func ensurePostProcessTextures(for drawableSize: CGSize) {
        let width = max(1, Int(drawableSize.width))
        let height = max(1, Int(drawableSize.height))

        if crtFallbackTexture == nil {
            crtFallbackTexture = makeCRTFallbackTexture()
        }

        if previousFrameTexture?.width != width || previousFrameTexture?.height != height {
            previousFrameTexture = makeCRTFrameTexture(width: width, height: height)
            hasCapturedPreviousFrame = false
        }

        if postProcessTexture?.width != width || postProcessTexture?.height != height {
            postProcessTexture = makePostProcessTexture(width: width, height: height)
        }

        if bloomConfiguration.isEnabled {
            ensureBloomTextures(width: width, height: height)
        } else {
            bloomBrightTexture = nil
            bloomBlurH = nil
            bloomBlurV = nil
        }
    }

    func makeCRTFrameTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        descriptor.resourceOptions = .storageModePrivate
        return device.makeTexture(descriptor: descriptor)
    }

    func makePostProcessTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        descriptor.resourceOptions = .storageModePrivate
        return device.makeTexture(descriptor: descriptor)
    }

    func makeSceneRenderPassDescriptor(
        texture: MTLTexture,
        clearColor: MTLClearColor
    ) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        return descriptor
    }

    func makeCRTFallbackTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        descriptor.resourceOptions = .storageModeShared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        var blackPixel: [UInt8] = [0, 0, 0, 255]
        blackPixel.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: 4
                )
            }
        }
        return texture
    }
}
