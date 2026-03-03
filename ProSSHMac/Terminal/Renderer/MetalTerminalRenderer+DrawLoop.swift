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
        if pendingRenderSnapshot == nil, !isDirty, !cursorRenderer.requiresContinuousFrames() {
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
            crtEnabled: postProcessingReady && crtConfiguration.isEnabled,
            scanlineOpacity: crtConfiguration.scanlineOpacity,
            scanlineDensity: crtConfiguration.scanlineDensity,
            barrelDistortion: crtConfiguration.barrelDistortion,
            phosphorBlend: phosphorBlend,
            contentScale: Float(screenScale),
            gradientConfig: gradientConfiguration,
            solidBackgroundConfig: solidBackgroundConfiguration,
            scannerConfig: scannerConfiguration,
            isLocalSession: isLocalSession
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
        guard !pendingGlyphKeys.isEmpty, glyphRasterTask == nil else { return }

        let keys = pendingGlyphKeys
        pendingGlyphKeys.removeAll()

        let scale = screenScale
        let cw = Int(ceil(cellWidth * scale))
        let ch = Int(ceil(cellHeight * scale))
        guard cw > 0, ch > 0 else { return }

        // Capture Sendable scalars only — CTFont is not Sendable, so recreate on background thread.
        rebuildRasterFontCacheIfNeeded(scale: scale)
        let fontName = rasterFontName
        let clampedScale = max(scale, 1.0)
        let scaledFontSize = rasterFontSize * clampedScale

        glyphRasterTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Reconstruct CTFont variants on the background thread from Sendable values.
            let base = CTFontCreateWithName(fontName as CFString, scaledFontSize, nil)
            let boldFont: CTFont = CTFontCreateCopyWithSymbolicTraits(
                base, scaledFontSize, nil, .boldTrait, .boldTrait) ?? base
            let italicFont: CTFont = CTFontCreateCopyWithSymbolicTraits(
                base, scaledFontSize, nil, .italicTrait, .italicTrait) ?? base
            let boldItalicTraits: CTFontSymbolicTraits = [.boldTrait, .italicTrait]
            let boldItalicFont: CTFont = CTFontCreateCopyWithSymbolicTraits(
                base, scaledFontSize, nil, boldItalicTraits, boldItalicTraits) ?? base

            var results: [(GlyphKey, RasterizedGlyph)] = []
            for key in keys {
                if Task.isCancelled { break }
                if let rasterized = MetalTerminalRenderer.rasterizeGlyphForBackground(
                    key: key, cellWidth: cw, cellHeight: ch,
                    regularFont: base, boldFont: boldFont,
                    italicFont: italicFont, boldItalicFont: boldItalicFont
                ) {
                    results.append((key, rasterized))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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

        if let atlasTexture = glyphAtlas.texture(forPage: 0) {
            renderEncoder.setFragmentTexture(atlasTexture, index: 0)
        }
        renderEncoder.setFragmentTexture(previousFrameTexture ?? crtFallbackTexture, index: 1)

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
}
