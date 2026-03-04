// Extracted from MetalTerminalRenderer.swift
import MetalKit
import AppKit

extension MetalTerminalRenderer {

    // MARK: - MTKViewDelegate: Resize (B.8.6)

    /// Called when the MTKView's drawable size changes (rotation, resize, etc.).
    ///
    /// - Parameters:
    ///   - view: The MTKView whose size changed.
    ///   - size: The new drawable size in pixels.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = size

        if usesNativeRefreshRate {
            setPreferredFPS(0)
        }

        // Detect screen scale factor from drawable-to-bounds ratio.
        let pointSize = view.bounds.size
        let hasValidBounds = pointSize.width > 0 && pointSize.height > 0
        let newScale: CGFloat
        if hasValidBounds && size.width > 0 {
            let measuredScale = max(size.width / pointSize.width, 1.0)
            // Keep scale aligned to physical backing scales (1x/2x/3x)
            // to avoid fractional atlas/cell drift and UV misalignment.
            newScale = max(1.0, round(measuredScale))
        } else {
            // Preserve current scale during transient zero-sized layout passes.
            newScale = screenScale
        }

        // If scale changed (e.g., window moved to a different display),
        // re-align cell dimensions and rebuild the atlas at the new pixel resolution.
        if abs(newScale - screenScale) > 0.01 {
            screenScale = newScale
            // Re-align cellWidth/cellHeight to the new screen scale so the
            // atlas slot size and shader cell size are identical (integer pixels).
            reapplyPixelAlignment()
            let cw = Int(round(cellWidth * screenScale))
            let ch = Int(round(cellHeight * screenScale))
            glyphAtlas.rebuild(cellWidth: cw, cellHeight: ch)
            glyphCache.clear()
            glyphCache.prePopulateASCII { [weak self] key in
                guard let self else { return nil }
                return self.rasterizeAndUpload(key: key)
            }
            if let latestSnapshot {
                updateSnapshot(latestSnapshot)
            }
            isDirty = true
        }

        // Recalculate grid dimensions in points.
        // During early layout passes, `bounds` can briefly be zero while
        // `drawableSize` is already valid. Fall back to drawable size when needed.
        let logicalWidth = pointSize.width > 0 ? pointSize.width : (size.width / max(newScale, 1.0))
        let logicalHeight = pointSize.height > 0 ? pointSize.height : (size.height / max(newScale, 1.0))

        // cellWidth/cellHeight are pixel-aligned points from the renderer.
        if cellWidth > 0, cellHeight > 0, logicalWidth > 0, logicalHeight > 0 {
            let newColumns = max(1, Int(logicalWidth / cellWidth))
            let newRows = max(1, Int(logicalHeight / cellHeight))

            if newColumns != gridColumns || newRows != gridRows {
                gridColumns = newColumns
                gridRows = newRows

                // Notify the cell buffer of the new dimensions.
                cellBuffer.resize(columns: newColumns, rows: newRows)
                smoothScrollEngine.handleResize()
                onGridSizeChange?(newColumns, newRows)
                isDirty = true
            }
        }
    }

    // MARK: - View Configuration (B.8.6)

    /// Configure an MTKView for terminal rendering.
    /// Sets up ProMotion frame rate, clear color, and pixel format.
    ///
    /// - Parameter view: The MTKView to configure.
    func configureView(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        configuredMTKView = view

        // B.8.6: ProMotion support — use native display refresh (60 Hz or 120 Hz).
        setPreferredFPS(0)

        // Dark terminal background.
        view.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        // Enable display link driven rendering.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        selectionRenderer.refreshSelectionColorFromSystemAccent()
    }

    // MARK: - Frame Rate Control (2.2.9 / 2.2.10)

    /// Pause or unpause rendering. Use for panes that are not visible
    /// (e.g. hidden behind a maximized pane or off-screen in another tab).
    func setPaused(_ paused: Bool) {
        configuredMTKView?.isPaused = paused
        if paused {
            stopCursorBlinkLoop()
        } else {
            updateCursorBlinkLoop()
        }
    }

    /// Set the preferred frames per second.
    /// Pass 0 to follow the current screen's native refresh rate.
    func setPreferredFPS(_ fps: Int) {
        guard let view = configuredMTKView else { return }
        usesNativeRefreshRate = fps <= 0
        if usesNativeRefreshRate {
            view.preferredFramesPerSecond = max(60, currentScreenMaximumFPS())
        } else {
            let nativeFPS = max(30, currentScreenMaximumFPS())
            view.preferredFramesPerSecond = min(max(1, fps), nativeFPS)
        }
    }

    func currentScreenMaximumFPS() -> Int {
        if let screenFPS = configuredMTKView?.window?.screen?.maximumFramesPerSecond {
            return screenFPS
        }
        if let mainFPS = NSScreen.main?.maximumFramesPerSecond {
            return mainFPS
        }
        return 60
    }

    // MARK: - Cursor Blink Loop

    /// Start a ~15fps blink animation loop if cursor is visible and blink enabled.
    /// The loop sets isDirty and unpauses the view on each tick.
    func startCursorBlinkLoopIfNeeded() {
        guard cursorBlinkTask == nil else { return }
        guard cursorVisible, cursorBlinkEnabled else { return }
        cursorBlinkTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(67)) // ~15fps
                guard !Task.isCancelled, let self else { break }
                self.isDirty = true
                self.configuredMTKView?.isPaused = false
            }
        }
    }

    /// Stop the cursor blink loop.
    func stopCursorBlinkLoop() {
        cursorBlinkTask?.cancel()
        cursorBlinkTask = nil
    }

    /// Start or stop the blink loop based on current cursor state.
    func updateCursorBlinkLoop() {
        if cursorVisible && cursorBlinkEnabled {
            startCursorBlinkLoopIfNeeded()
        } else {
            stopCursorBlinkLoop()
        }
    }
}
