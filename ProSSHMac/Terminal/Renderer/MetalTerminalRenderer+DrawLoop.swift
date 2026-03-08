// Extracted from MetalTerminalRenderer.swift
import Metal
import MetalKit
import QuartzCore
import simd

extension MetalTerminalRenderer {

    // MARK: - MTKViewDelegate: Draw (B.8.3, B.8.4)

    /// Called each frame by the MTKView display link.
    /// Implements the full draw loop with in-flight synchronization.
    ///
    /// - Parameter view: The MTKView requesting a draw.
    func draw(in view: MTKView) {
        let frameNow = CACurrentMediaTime()
        if pendingRenderSnapshot == nil, !isDirty, !requiresContinuousFrames() {
            view.isPaused = true
            return
        }

        if usesNativeRefreshRate {
            let targetFPS = max(60, currentScreenMaximumFPS())
            if view.preferredFramesPerSecond != targetFPS {
                view.preferredFramesPerSecond = targetFPS
            }
        }

        // Wait on in-flight semaphore before reusing cell buffers.
        _ = inflightSemaphore.wait(timeout: .distantFuture)

        // Get current drawable and render pass descriptor.
        guard let drawable = view.currentDrawable else {
            inflightSemaphore.signal()
            return
        }

        guard let drawableRenderPassDescriptor = view.currentRenderPassDescriptor else {
            inflightSemaphore.signal()
            return
        }

        // Create command buffer.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return
        }
        #if DEBUG
        commandBuffer.label = "TerminalFrame"
        #endif

        let drawableSize = view.drawableSize
        let scannerActive = scannerConfiguration.isEnabled && isLocalSession
        let usesPostProcessing = crtConfiguration.isEnabled
            || gradientConfiguration.isEnabled
            || solidBackgroundConfiguration.isEnabled
            || scannerActive
            || bloomConfiguration.isEnabled
        if usesPostProcessing {
            ensurePostProcessTextures(for: drawableSize)
        }

        let postProcessingReady = usesPostProcessing &&
            postProcessTexture != nil &&
            previousFrameTexture != nil

        // Apply latest pending snapshot in a buffer-safe context.
        applyPendingSnapshotIfNeeded()
        drainPendingGlyphKeysIfNeeded()

        // Update uniforms for this frame via the TerminalUniformBuffer.
        let cursorFrame = cursorRenderer.frame(at: frameNow)
        let scrollFrame = smoothScrollEngine.frame(cellHeight: cellHeight * screenScale, time: frameNow)
        let frameDelta = max(0, uniformBuffer.currentTime - previousUniformTime)
        let phosphorBlend = (postProcessingReady && hasCapturedPreviousFrame)
            ? CRTEffect.phosphorBlend(
                persistence: crtConfiguration.phosphorPersistence,
                frameDeltaSeconds: frameDelta
            )
            : 0.0

        // Pass cellSize and viewportSize in pixel space for Retina-correct rendering.
        // cellSize = point dimensions × screenScale, viewportSize = drawableSize.
        // The shader uses these consistently for NDC conversion and atlas UV mapping.
        uniformBuffer.update(
            cellSize: SIMD2<Float>(Float(cellWidth * screenScale), Float(cellHeight * screenScale)),
            viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            atlasSize: SIMD2<Float>(Float(glyphAtlas.pageSize), Float(glyphAtlas.pageSize)),
            cursorRenderRow: cursorFrame.row,
            cursorRenderCol: cursorFrame.col,
            cursorStyle: cursorFrame.style,
            cursorVisible: cursorVisible,
            cursorBlinkEnabled: cursorBlinkEnabled,
            cursorPhaseOverride: cursorFrame.phase,
            glowIntensity: cursorFrame.glowIntensity,
            selectionAlpha: selectionRenderer.selectionAlpha,
            selectionColor: selectionRenderer.selectionColor,
            boldTextColorConfig: boldTextColorConfiguration,
            crtEnabled: postProcessingReady && crtConfiguration.isEnabled,
            scanlineOpacity: crtConfiguration.scanlineOpacity,
            scanlineDensity: crtConfiguration.scanlineDensity,
            barrelDistortion: crtConfiguration.barrelDistortion,
            phosphorBlend: phosphorBlend,
            contentScale: Float(screenScale),
            gradientConfig: gradientConfiguration,
            solidBackgroundConfig: solidBackgroundConfiguration,
            scannerConfig: scannerConfiguration,
            bloomConfig: bloomConfiguration,
            isLocalSession: isLocalSession,
            scrollOffsetPixels: scrollFrame.offsetPixels
        )
        previousUniformTime = uniformBuffer.currentTime

        let frameStart = frameNow
        let frameSignpostID = performanceMonitor.beginFrame()
        var drawCalls = 0

        if postProcessingReady, let sceneTexture = postProcessTexture {
            let sceneRenderPassDescriptor = makeSceneRenderPassDescriptor(
                texture: sceneTexture,
                clearColor: view.clearColor
            )

            guard let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneRenderPassDescriptor) else {
                inflightSemaphore.signal()
                return
            }
            sceneEncoder.label = "TerminalSceneEncoder"
            drawCalls += encodeTerminalScenePass(sceneEncoder, drawableSize: drawableSize)
            sceneEncoder.endEncoding()

            // Bloom bright-pass: extract luminant pixels → bloomBrightTexture (half-res)
            encodeBrightPass(commandBuffer: commandBuffer, sceneTexture: sceneTexture)
            // Bloom blur: H+V separable Gaussian → bloomBlurV (ready for Phase 4 composite)
            encodeBlurPasses(commandBuffer: commandBuffer)

            guard let postEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawableRenderPassDescriptor) else {
                inflightSemaphore.signal()
                return
            }
            postEncoder.label = "TerminalPostProcessEncoder"

            let viewport = MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(drawableSize.width),
                height: Double(drawableSize.height),
                znear: 0,
                zfar: 1
            )
            postEncoder.setViewport(viewport)

            let scissorRect = MTLScissorRect(
                x: 0,
                y: 0,
                width: Int(drawableSize.width),
                height: Int(drawableSize.height)
            )
            postEncoder.setScissorRect(scissorRect)

            postEncoder.setRenderPipelineState(postProcessPipelineState)
            postEncoder.setFragmentBuffer(uniformBuffer.buffer, offset: 0, index: 1)
            postEncoder.setFragmentTexture(sceneTexture, index: 0)
            postEncoder.setFragmentTexture(previousFrameTexture ?? crtFallbackTexture, index: 1)
            let effectiveBloomTex = bloomConfiguration.isEnabled ? bloomBlurV : nil
            postEncoder.setFragmentTexture(effectiveBloomTex ?? crtFallbackTexture, index: 2)
            postEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            postEncoder.endEncoding()
            drawCalls += 1

            // Save scene output for phosphor history sampling on the next frame.
            if let historyTexture = previousFrameTexture,
               let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.label = "TerminalCRTFrameHistoryCopy"
                let copyWidth = min(sceneTexture.width, historyTexture.width)
                let copyHeight = min(sceneTexture.height, historyTexture.height)
                if copyWidth > 0, copyHeight > 0 {
                    blitEncoder.copy(
                        from: sceneTexture,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                        to: historyTexture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    hasCapturedPreviousFrame = true
                }
                blitEncoder.endEncoding()
            }
        } else {
            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: drawableRenderPassDescriptor) else {
                inflightSemaphore.signal()
                return
            }
            renderEncoder.label = "TerminalRenderEncoder"
            drawCalls += encodeTerminalScenePass(renderEncoder, drawableSize: drawableSize)
            renderEncoder.endEncoding()
        }

        // Present drawable.
        commandBuffer.present(drawable)

        // B.8.7: Signal semaphore when GPU work completes.
        let semaphore = inflightSemaphore
        let cpuFrameDuration = CACurrentMediaTime() - frameStart
        performanceMonitor.endFrame(
            signpostID: frameSignpostID,
            cpuFrameSeconds: cpuFrameDuration,
            gpuFrameSeconds: nil,
            drawCalls: drawCalls
        )
        #if DEBUG
        let _snap = performanceMonitor.snapshot()
        if _snap.totalFrames > 0, _snap.totalFrames % 300 == 0 {
            let hr = String(format: "%.1f", glyphCache.hitRate * 100)
            print("[Renderer] avg=\(String(format: "%.2f", _snap.averageCPUFrameMs))ms"
                + " p95=\(String(format: "%.2f", _snap.p95CPUFrameMs))ms"
                + " dropped60=\(_snap.dropped60HzFrames) dropped120=\(_snap.dropped120HzFrames)"
                + " | GlyphCache hit=\(hr)%")
        }
        #endif
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        // Commit the command buffer.
        commandBuffer.commit()

        isDirty = false
    }

    /// Drain any glyph keys that missed the cache this frame by launching a single
    /// background rasterization task. New misses during an in-flight task accumulate
    /// in `pendingGlyphKeys` and are processed on the next pass (triggered by `isDirty = true`).
    private func drainPendingGlyphKeysIfNeeded() {
        guard isFontStateReady, !pendingGlyphKeys.isEmpty, glyphRasterTask == nil else { return }

        let keys = pendingGlyphKeys
        pendingGlyphKeys.removeAll()
        let generation = glyphRasterGeneration

        let scale = screenScale
        let cw = Int(ceil(cellWidth * scale))
        let ch = Int(ceil(cellHeight * scale))
        guard cw > 0, ch > 0 else { return }

        // Ensure font cache is current, then capture the Sendable font set for the background task.
        rebuildRasterFontCacheIfNeeded(scale: scale)
        guard let fontSet = cachedRasterFontSet else { return }

        glyphRasterTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Local rasterizer instance — scratch buffer reused across all keys in this batch.
            let rasterizer = GlyphRasterizer()

            var results: [(GlyphKey, RasterizedGlyph)] = []
            for key in keys {
                if Task.isCancelled { break }
                if let rasterized = MetalTerminalRenderer.rasterizeGlyphForBackground(
                    key: key, cellWidth: cw, cellHeight: ch,
                    fontSet: fontSet,
                    rasterizer: rasterizer
                ) {
                    results.append((key, rasterized))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.glyphRasterGeneration else {
                    self.glyphRasterTask = nil
                    if !self.pendingGlyphKeys.isEmpty {
                        self.requestFrame()
                    }
                    return
                }
                for (key, rasterized) in results {
                    guard !self.glyphCache.contains(key) else { continue }
                    let entry = rasterized.pixelData.withUnsafeBufferPointer { ptr -> AtlasEntry? in
                        guard let base = ptr.baseAddress else { return nil }
                        return self.glyphAtlas.allocate(
                            width: rasterized.width, height: rasterized.height,
                            pixelData: base,
                            bearingX: Int8(clamping: rasterized.bearingX),
                            bearingY: Int8(clamping: rasterized.bearingY)
                        )
                    }
                    if let entry { self.glyphCache.insert(key, entry: entry) }
                }
                self.glyphRasterTask = nil
                // Force re-render: re-apply current snapshot so noGlyphIndex cells are
                // replaced now that their entries are in the cache.
                self.pendingRenderSnapshot = self.latestSnapshot
                self.forceFullUploadForPendingSnapshot = true
                self.isDirty = true
                self.requestFrame()
            }
        }
    }

    func encodeTerminalScenePass(
        _ renderEncoder: MTLRenderCommandEncoder,
        drawableSize: CGSize
    ) -> Int {
        let viewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(drawableSize.width),
            height: Double(drawableSize.height),
            znear: 0,
            zfar: 1
        )
        renderEncoder.setViewport(viewport)

        let scissorRect = MTLScissorRect(
            x: 0,
            y: 0,
            width: Int(drawableSize.width),
            height: Int(drawableSize.height)
        )
        renderEncoder.setScissorRect(scissorRect)

        renderEncoder.setRenderPipelineState(pipelineState)

        if let readBuffer = cellBuffer.readBuffer {
            renderEncoder.setVertexBuffer(readBuffer, offset: 0, index: 0)
        }
        renderEncoder.setVertexBuffer(uniformBuffer.buffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(uniformBuffer.buffer, offset: 0, index: 1)

        let atlasTextures = (0..<GlyphAtlas.maxPageCount).map { glyphAtlas.texture(forPage: $0) }
        renderEncoder.setFragmentTextures(
            atlasTextures,
            range: 0..<GlyphAtlas.maxPageCount
        )
        renderEncoder.setFragmentTexture(
            previousFrameTexture ?? crtFallbackTexture,
            index: GlyphAtlas.maxPageCount
        )

        let instanceCount = cellBuffer.cellCount
        guard instanceCount > 0 else { return 0 }

        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instanceCount
        )
        return 1
    }

    // MARK: - Bloom Bright-Pass Encoding

    private func encodeBrightPass(
        commandBuffer: MTLCommandBuffer,
        sceneTexture: MTLTexture
    ) {
        guard bloomConfiguration.isEnabled,
              let pipeline = bloomBrightPipeline,
              let target = bloomBrightTexture else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "BloomBrightPass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(sceneTexture, index: 0)
        encoder.setFragmentBuffer(uniformBuffer.buffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Bloom Blur Encoding (H + V Separable Gaussian)

    private func encodeBlurPasses(commandBuffer: MTLCommandBuffer) {
        guard bloomConfiguration.isEnabled,
              let pipeline = bloomBlurHPipeline,
              let brightTex = bloomBrightTexture,
              let blurHTex = bloomBlurH,
              let blurVTex = bloomBlurV else { return }

        // Compute effective radius: subtle cosine pulse for aurora/wave gradient modes.
        let gradientIsAnimating = gradientConfiguration.isEnabled
            && gradientConfiguration.animationMode != .none
        let effectiveRadius: Float
        if bloomConfiguration.animateWithGradient && gradientIsAnimating
            && (gradientConfiguration.animationMode == .aurora
                || gradientConfiguration.animationMode == .wave) {
            let elapsed = Float(uniformBuffer.currentTime)
            effectiveRadius = bloomConfiguration.radius
                * (0.9 + 0.1 * cos(elapsed * max(0.01, gradientConfiguration.animationSpeed)))
        } else {
            effectiveRadius = bloomConfiguration.radius
        }

        struct BloomBlurParams {
            var texelWidth: Float
            var texelHeight: Float
            var horizontal: Float
            var radius: Float
        }

        // H-pass: bloomBrightTexture → bloomBlurH
        var hParams = BloomBlurParams(
            texelWidth:  1.0 / Float(brightTex.width),
            texelHeight: 1.0 / Float(brightTex.height),
            horizontal:  1.0,
            radius:      effectiveRadius
        )
        let hDescriptor = MTLRenderPassDescriptor()
        hDescriptor.colorAttachments[0].texture = blurHTex
        hDescriptor.colorAttachments[0].loadAction = .dontCare
        hDescriptor.colorAttachments[0].storeAction = .store

        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: hDescriptor) {
            enc.label = "BloomBlurHPass"
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(brightTex, index: 0)
            enc.setFragmentBytes(&hParams, length: MemoryLayout<BloomBlurParams>.size, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // V-pass: bloomBlurH → bloomBlurV
        var vParams = BloomBlurParams(
            texelWidth:  1.0 / Float(blurHTex.width),
            texelHeight: 1.0 / Float(blurHTex.height),
            horizontal:  0.0,
            radius:      effectiveRadius
        )
        let vDescriptor = MTLRenderPassDescriptor()
        vDescriptor.colorAttachments[0].texture = blurVTex
        vDescriptor.colorAttachments[0].loadAction = .dontCare
        vDescriptor.colorAttachments[0].storeAction = .store

        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: vDescriptor) {
            enc.label = "BloomBlurVPass"
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(blurHTex, index: 0)
            enc.setFragmentBytes(&vParams, length: MemoryLayout<BloomBlurParams>.size, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }
}
