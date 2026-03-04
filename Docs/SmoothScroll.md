# SmoothScroll — Smooth Scrolling with Momentum

## Overview

Replace the current discrete line-jump scroll behavior in ProSSHMac's Metal terminal renderer with
sub-pixel smooth scrolling driven by spring/inertia physics on the CPU and a float offset in the
GPU vertex shader. The terminal feels buttery and responsive — scrollback glides instead of snapping,
and momentum carries naturally after a trackpad flick.

### Goal
Implement a smooth scroll pipeline: float scroll offset uniform → vertex shader Y-shift →
CPU-side physics engine (spring interpolation + momentum decay) → integration with existing
`CursorRenderer` lerp pattern.

### Architecture Sketch

```
[NSEvent scrollWheel]
       │
       ▼
TerminalMetalContainerView.scrollWheel()
       │ (currently: accumulate → fire onScroll(Int lines))
       │ (new: feed raw deltaY into SmoothScrollEngine)
       ▼
SmoothScrollEngine                          ← NEW: CPU-side physics
  ├── targetScrollRow: Int                  (discrete buffer position)
  ├── currentOffset: Float                  (fractional row offset, animated)
  ├── velocity: Float                       (momentum, decays per frame)
  └── frame() → SmoothScrollFrame           (called each render tick)
       │
       ▼
TerminalUniformData.scrollOffsetPixels      ← NEW uniform field
       │
       ▼
terminal_vertex (TerminalShaders.metal)
  └── pixelPos.y += scrollOffsetPixels      (applied BEFORE NDC division)
       │
       ▼
terminal_post_fragment
  └── adjust cursor glow / scanner / bloom UV by same offset
```

### Affected Files

| File | Change |
|---|---|
| `Terminal/Renderer/TerminalShaders.metal` | Add `scrollOffsetPixels` to `TerminalUniforms` struct, apply Y-shift in `terminal_vertex`, adjust post-process effects that use pixel coordinates |
| `Terminal/Renderer/TerminalUniforms.swift` | Add `scrollOffsetPixels: Float` to `TerminalUniformData`, wire in `TerminalUniformBuffer.update()` |
| `Terminal/Renderer/TerminalMetalView.swift` | Rework `scrollWheel()` to feed raw `scrollingDeltaY` into `SmoothScrollEngine` instead of integer line accumulation |
| `Terminal/Renderer/SmoothScrollEngine.swift` | New: physics engine — target tracking, spring interpolation, momentum decay, clamping |
| `Terminal/Renderer/MetalTerminalRenderer.swift` | Own `SmoothScrollEngine` instance, call `frame()` each render tick, upload offset to uniforms |
| `Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift` | Request continuous frames when scroll is animating (same pattern as `CursorRenderer.requiresContinuousFrames()`) |
| `Terminal/Effects/SmoothScrollConfiguration.swift` | New: config struct with persistence (enable/disable, spring stiffness, friction, momentum toggle) |
| `UI/Settings/SmoothScrollSettingsView.swift` | New: settings sub-view |
| `UI/Settings/SettingsView.swift` | Add smooth scroll row |

---

## Phased Checklist

### - [ ] Phase 0: Configuration & Uniforms

**Goal:** Lay the data foundation — config struct, persistence, uniform field — before touching scroll behavior.

**Tasks:**
- Create `Terminal/Effects/SmoothScrollConfiguration.swift`:
  - `SmoothScrollConfiguration: Codable, Equatable` with fields:
    - `isEnabled: Bool` (default: `true`)
    - `springStiffness: Float` (default: `0.30`) — lerp factor per frame (higher = snappier, 0.15–0.50 range)
    - `friction: Float` (default: `0.92`) — momentum velocity multiplier per frame (0.85–0.97 range)
    - `momentumEnabled: Bool` (default: `true`) — carry velocity after trackpad release
    - `maxVelocity: Float` (default: `80.0`) — velocity cap in rows/sec to prevent runaway scrolling
  - `static func load(from: UserDefaults) -> SmoothScrollConfiguration`
  - `func save(to: UserDefaults)` — key: `"terminal.effects.smoothScroll"`
  - `static let `default`: SmoothScrollConfiguration`
- Add to `TerminalUniformData` (in `TerminalUniforms.swift`):
  - `scrollOffsetPixels: Float` — vertical pixel offset for sub-row scrolling
  - (Keep Metal struct 16-byte aligned — add padding if needed. Check existing alignment padding pattern)
- Wire in `TerminalUniformBuffer.update()`:
  - Set `scrollOffsetPixels` from renderer's `SmoothScrollEngine.currentFrame.offsetPixels`
  - For now, hardcode to `0.0` — no visual change yet
- Mirror the field in `TerminalShaders.metal` `TerminalUniforms` struct:
  - Add `float scrollOffsetPixels;` at the correct offset position matching Swift struct layout
  - **CRITICAL:** The byte offset must match exactly. Follow the existing padding pattern. Add `float _scrollPad0;` etc. if needed
- Verify: `xcodebuild build` — no compiler errors. No visual change yet.

---

### - [ ] Phase 1: SmoothScrollEngine (CPU Physics)

**Goal:** Build the animation engine that tracks scroll state, applies spring interpolation and momentum decay. No GPU changes yet — just the model.

**Tasks:**
- Create `Terminal/Renderer/SmoothScrollEngine.swift`:
  - Follow `CursorRenderer` pattern: target state → interpolated render state per frame
  - State:
    ```swift
    /// The discrete scrollback row that the terminal buffer is positioned at.
    private(set) var targetScrollRow: Int = 0
    
    /// Fractional offset in rows from the target position (range: -1.0 to +1.0).
    /// Positive = content shifted down (mid-scroll-up animation).
    private var renderOffset: Float = 0.0
    
    /// Current scroll velocity in rows per frame (for momentum).
    private var velocity: Float = 0.0
    
    /// Whether a momentum phase is active (trackpad released with velocity).
    private var inMomentum: Bool = false
    ```
  - Public API:
    ```swift
    /// Feed raw scroll delta from NSEvent (in points, not rows).
    func scrollDelta(_ deltaPoints: CGFloat, cellHeight: CGFloat)
    
    /// Called when NSEvent phase == .ended — start momentum if enabled.
    func beginMomentum()
    
    /// Called when NSEvent momentumPhase == .ended — stop momentum.
    func endMomentum()
    
    /// Advance one render frame. Returns the pixel offset to upload to GPU.
    func frame(cellHeight: CGFloat) -> SmoothScrollFrame
    
    /// Whether continuous frame updates are needed (animation in progress).
    func requiresContinuousFrames() -> Bool
    
    /// Callback: fires when targetScrollRow changes (integer), so the terminal
    /// buffer can actually scroll to the new position.
    var onScrollLineChange: ((Int) -> Void)?
    ```
  - `SmoothScrollFrame` struct:
    ```swift
    struct SmoothScrollFrame: Sendable {
        /// Pixel offset to apply in vertex shader (sub-row position).
        let offsetPixels: Float
        /// Whether the animation is still in progress.
        let isAnimating: Bool
    }
    ```
  - `scrollDelta()` logic:
    - Accumulate `deltaPoints / cellHeight` into `renderOffset`
    - When `abs(renderOffset) >= 1.0`: extract integer rows, fire `onScrollLineChange`, keep fractional remainder
    - Track velocity as exponential moving average of recent deltas
  - `frame()` logic:
    - If `inMomentum && momentumEnabled`:
      - Apply `velocity` to `renderOffset`
      - `velocity *= config.friction` (decay)
      - Extract integer rows when `abs(renderOffset) >= 1.0`
      - Stop momentum when `abs(velocity) < 0.01`
    - If not in momentum and `abs(renderOffset) > snapEpsilon`:
      - Spring back: `renderOffset = lerp(renderOffset, 0.0, config.springStiffness)`
      - Snap to zero when below epsilon (same pattern as `CursorRenderer`)
    - Return `SmoothScrollFrame(offsetPixels: renderOffset * cellHeight, isAnimating: ...)`
  - Clamp `velocity` to `±config.maxVelocity`
  - Clamp `renderOffset` to `±1.5` rows (prevent visual overscroll beyond one row)
- Add unit tests in `ProSSHMacTests/SmoothScrollEngineTests.swift`:
  - Test: feed delta → integer row change fires callback at correct threshold
  - Test: momentum decay converges to zero
  - Test: spring-back from fractional offset converges to zero
  - Test: velocity clamping
- Verify: unit tests pass. No visual change in app.

---

### - [ ] Phase 2: Vertex Shader Integration

**Goal:** Apply `scrollOffsetPixels` in the vertex shader so the GPU shifts all cell quads vertically by the sub-pixel offset.

**Tasks:**
- In `TerminalShaders.metal`, modify `terminal_vertex`:
  - After computing `pixelPos` from `cellOrigin + corner * cellSize`, add:
    ```metal
    // Smooth scroll: sub-pixel vertical offset (applied before NDC conversion
    // to avoid scaling artifacts on non-square viewports).
    pixelPos.y += uniforms.scrollOffsetPixels;
    ```
  - This goes **after** `float2 pixelPos = cellOrigin + corner * uniforms.cellSize;` and **before** the NDC transform block (`float2 ndc; ndc.x = ...`)
  - **CRITICAL:** The offset is in pixel space, not NDC space. Applying in NDC would scale incorrectly with aspect ratio
- In `terminal_fragment`, adjust `fragPixel` for cursor hit-testing:
  - The cursor position (`cursorOrigin`) is computed from `cursorRenderRow * cellSize`. The cursor does NOT scroll with content (it's always at its grid position). But `cellPixelPos` in `VertexOut` now includes the scroll offset, so cursor overlap detection needs compensation:
    ```metal
    // Compensate for smooth scroll offset in cursor hit-testing.
    float2 fragPixel = in.cellPixelPos + (in.cellUV * uniforms.cellSize);
    // Cursor is rendered at its absolute grid position (not scrolled).
    // fragPixel already includes scrollOffsetPixels from vertex shader.
    // cursorOrigin does NOT include it, so comparison works correctly:
    // when scrolling, the cells shift but the cursor overlay doesn't.
    ```
  - **Wait — think about this carefully.** The cursor cell itself IS part of the instanced cells, so it shifts with `scrollOffsetPixels` too. The cursor overlay in the fragment shader compares `fragPixel` to `cursorOrigin`. Since both the cell origin and the cursor origin would need to agree, one of two approaches:
    - **Option A (recommended):** Also offset `cursorOrigin` by `scrollOffsetPixels` in the fragment shader. This keeps cursor and content in sync.
    - **Option B:** Subtract `scrollOffsetPixels` from `fragPixel.y` before cursor comparison. Same result.
  - Choose Option A — simpler mental model:
    ```metal
    float2 cursorOrigin = float2(
        uniforms.cursorRenderCol * uniforms.cellSize.x,
        uniforms.cursorRenderRow * uniforms.cellSize.y + uniforms.scrollOffsetPixels
    );
    ```
- In `terminal_post_fragment`, adjust scanner effect pixel calculation:
  - The scanner uses `float2 pixel = uv * uniforms.viewportSize` to find the row. The post-process pass operates on the rendered texture (which already has the scroll offset baked in from the vertex shader), so **no adjustment needed** — the scanner naturally tracks the shifted content.
  - **However:** verify this empirically. If the scanner is computed from `cursorRenderRow`, it might need the same offset. Add a `// SMOOTH_SCROLL: verified — scanner uses rendered UVs` comment after testing.
- Bloom integration (if Phase 2 of TextGlow is complete):
  - Bloom operates on `postProcessTexture` which already contains shifted pixels. No change needed — bloom naturally blurs the shifted content.
- Verify: with `scrollOffsetPixels` hardcoded to e.g. `cellSize.y * 0.5` in uniforms update, all cells should render shifted down by half a row. Cursor glow should follow. Scanner should track.

---

### - [ ] Phase 3: Wire Scroll Events Through Engine

**Goal:** Replace the integer-line accumulation in `TerminalMetalContainerView.scrollWheel()` with `SmoothScrollEngine`, connecting raw NSEvent deltas to the GPU offset.

**Tasks:**
- In `MetalTerminalRenderer.swift`:
  - Add `let smoothScrollEngine = SmoothScrollEngine()`
  - In `init()` or `configureView()`, wire up `smoothScrollEngine.onScrollLineChange`:
    - This callback replaces the existing `onScroll?(lines)` path
    - It fires when the engine's `targetScrollRow` changes by integer rows
    - Connect it to whatever scrollback controller the existing `onScroll` callback targets
  - Add public method `func scrollDelta(_ deltaPoints: CGFloat)` that forwards to engine
  - Add public method `func scrollMomentumBegan()` / `scrollMomentumEnded()`
- In `TerminalMetalView.swift`:
  - Change `TerminalMetalContainerView.scrollWheel()` from:
    ```swift
    // OLD: integer accumulation
    accumulatedScrollY += event.scrollingDeltaY
    let lines = Int(accumulatedScrollY / lineThreshold)
    if lines != 0 { onScroll?(lines); ... }
    ```
    To:
    ```swift
    // NEW: feed raw delta to engine
    renderer.scrollDelta(event.scrollingDeltaY)
    
    // Track scroll phases for momentum
    if event.phase == .ended {
        renderer.smoothScrollEngine.beginMomentum()
    }
    if event.momentumPhase == .ended {
        renderer.smoothScrollEngine.endMomentum()
    }
    ```
  - Remove `accumulatedScrollY` state — the engine owns accumulation now
  - Keep `onScroll` callback in `TerminalMetalView` but wire it through the engine's `onScrollLineChange`
  - **Fallback:** When `SmoothScrollConfiguration.isEnabled == false`, use the old integer accumulation path. Wrap in `if renderer.smoothScrollEnabled { ... } else { ... }`
- In `TerminalUniformBuffer.update()`:
  - Replace the hardcoded `0.0` from Phase 0 with `smoothScrollEngine.currentFrame.offsetPixels`
- In `MetalTerminalRenderer+DrawLoop.swift`:
  - Add `smoothScrollEngine.requiresContinuousFrames()` to the `needsContinuousFrames` check (same location where `cursorRenderer.requiresContinuousFrames()` is checked)
  - This ensures the display link keeps firing during scroll animation
- In the render tick (wherever `cursorRenderer.frame(at: time)` is called):
  - Also call `smoothScrollEngine.frame(cellHeight: currentCellHeight)` and store the result
  - The stored result feeds into uniform upload
- Verify: trackpad scroll should now produce smooth sub-pixel vertical movement. Content glides. Releasing with velocity should show momentum decay. Scrolling should still correctly navigate scrollback (integer row changes still fire).

---

### - [ ] Phase 4: Edge Cases & Overscroll Behavior

**Goal:** Handle all the tricky edge cases that make smooth scrolling feel polished vs janky.

**Tasks:**
- **Top/bottom clamping:**
  - When at the top of scrollback (row 0), `scrollOffsetPixels` must not go positive (can't scroll past the beginning)
  - When at the bottom (live terminal), `scrollOffsetPixels` must not go negative (can't scroll past the end)
  - In `SmoothScrollEngine.scrollDelta()`: check against bounds before accumulating
  - Add `func setBounds(minRow: Int, maxRow: Int)` — called by the renderer when scrollback size changes
- **Rubber band overscroll (optional but nice):**
  - When user scrolls past bounds, allow `renderOffset` to extend to ±0.3 rows with increased spring stiffness (3× normal), creating a rubber-band feel
  - On release, spring snaps back to 0 quickly
  - Only when `momentumEnabled == true`
- **Programmatic scroll (jump-to-bottom, search result navigation):**
  - When the terminal programmatically scrolls (e.g., new output arrives while at bottom, or user clicks a search result), the engine should snap immediately:
  - Add `func jumpTo(row: Int)` — sets `targetScrollRow`, zeroes `renderOffset` and `velocity`, fires callback
  - No animation for programmatic scrolls — only user-initiated scrolls animate
- **Resize handling:**
  - When the terminal resizes, `cellHeight` changes. The engine uses `cellHeight` to convert between pixel deltas and row offsets. On resize:
  - Snap `renderOffset` to 0, zero velocity, let the grid re-render at the new size
  - Add `func handleResize()` that resets animation state
- **Pane splitting:**
  - Each pane has its own renderer and thus its own `SmoothScrollEngine`. No cross-pane interference.
  - Verify: split panes scroll independently with smooth scrolling
- **High refresh rate (120Hz ProMotion):**
  - The physics engine uses per-frame constants (`friction`, `springStiffness`). At 120Hz these are applied 2× per 60Hz interval, making animation faster.
  - **Fix:** Make physics frame-rate-independent by incorporating `deltaTime`:
    ```swift
    let dt = Float(min(currentTime - lastFrameTime, 1.0 / 30.0)) // cap to prevent huge jumps
    renderOffset = lerp(renderOffset, 0.0, 1.0 - pow(1.0 - springStiffness, dt * 60.0))
    velocity *= pow(friction, dt * 60.0)
    ```
  - This normalizes behavior to 60fps-equivalent regardless of actual frame rate
- Verify: scroll to top of scrollback → can't overscroll past beginning. New output → jumps to bottom cleanly. Resize → no visual glitch. 120Hz display → same scroll feel as 60Hz.

---

### - [ ] Phase 5: Settings UI

**Goal:** Expose smooth scrolling as a user-configurable feature in Settings, consistent with existing effects UX.

**Tasks:**
- Create `UI/Settings/SmoothScrollSettingsView.swift`:
  ```
  SmoothScrollSettingsView
  ├── Toggle "Enable Smooth Scrolling"
  ├── (when enabled) Section "Scroll Physics"
  │     ├── Slider "Snap Speed" (0.15–0.50, step 0.05) — label: "Spring stiffness"
  │     │     subtitle: "How quickly scroll snaps to target row"
  │     ├── Slider "Momentum Decay" (0.85–0.97, step 0.01) — label: "Friction"
  │     │     subtitle: "Higher = longer coast after release"
  │     ├── Toggle "Enable Momentum" — carry velocity after trackpad release
  │     └── Slider "Max Speed" (20.0–120.0, step 10.0) — label: "Velocity cap"
  │           subtitle: "Prevents runaway scrolling on fast flicks"
  └── Button "Reset to Defaults"
  ```
  - On any change: call `config.save(to: .standard)` + reload in engine
  - Follow existing `GradientBackgroundSettingsView` / `BloomEffectSettingsView` patterns
- In `UI/Settings/SettingsView.swift`:
  - Add row in the Terminal section (below Bloom Glow or wherever effects live):
    ```swift
    NavigationLink(destination: SmoothScrollSettingsView()) {
        HStack {
            Label("Smooth Scrolling", systemImage: "arrow.up.arrow.down.circle")
            Spacer()
            if SmoothScrollConfiguration.load(from: .standard).isEnabled {
                Text("On").foregroundColor(.green)
            }
        }
    }
    ```
- `SmoothScrollEngine` should reload config from UserDefaults at the start of each scroll gesture (not every frame — too expensive). Add `func reloadConfiguration()` called from `scrollWheel` on `.began` phase.
- Verify: settings navigation works, values persist across app restarts, changing friction mid-scroll takes effect on next gesture.

---

### - [ ] Phase 6: QA, Performance & Polish

**Goal:** Validate correctness, measure CPU overhead, handle edge cases, tune defaults.

**Tasks:**
- Performance profiling:
  - `SmoothScrollEngine.frame()` should be < 0.01ms (it's just arithmetic). Verify with Instruments.
  - The vertex shader change is a single float addition — zero measurable GPU overhead.
  - **The real cost** is requesting continuous frames during animation. Verify that the display link stops firing once `requiresContinuousFrames()` returns `false` (same as cursor animation).
- Tuning defaults (iterate with real scrollback content):
  - `springStiffness: 0.30` — try 0.25 and 0.35, find the sweet spot
  - `friction: 0.92` — try 0.90 (shorter coast) and 0.95 (longer coast)
  - The goal: scroll should feel like Safari's smooth scroll, not like a physics simulation
  - Test with: `cat /var/log/syslog` (thousands of lines), `htop` (live-updating), `man bash` (manual paging)
- Edge cases:
  - **Rapid direction change:** scroll up then immediately scroll down — no jank, offset reverses smoothly
  - **Mouse wheel (discrete):** non-trackpad mice send `hasPreciseScrollingDeltas == false`. These should use a fixed delta (e.g., 3 rows per tick) instead of the raw `scrollingDeltaY`. Check `event.hasPreciseScrollingDeltas` in `scrollWheel()` and scale accordingly
  - **Page Up/Page Down keys:** these should call `jumpTo(row:)`, not animate
  - **Alternate screen buffer** (vim, less, htop): when the terminal switches to alt screen, reset scroll state. The alt screen has its own scroll semantics
  - **Selection during scroll:** if the user is selecting text while smooth-scrolling, selection coordinates must account for the sub-pixel offset. Verify that `SelectionRenderer` still works correctly — since selection is rendered as per-cell attributes (FLAG_SELECTED), the vertex offset applies uniformly and selection should track correctly. Test empirically.
  - **Accessibility:** respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. When true, disable smooth scrolling (instant jump, no animation). Check this in `SmoothScrollEngine.init()` or `reloadConfiguration()`.
- Run full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
- Update `Docs/featurelist.md` with dated entry
- Update `CLAUDE.md` if new key files or architecture conventions were added
- Commit all changes

---

## Key Architecture Notes

### Scroll event flow (final)
```
1. NSEvent.scrollWheel                              (AppKit)
2. TerminalMetalContainerView.scrollWheel()         (raw delta dispatch)
3. SmoothScrollEngine.scrollDelta()                 (accumulate, extract rows)
4.   └── onScrollLineChange(±N)                     (integer row change)
5.       └── Terminal buffer adjusts scrollback      (existing path)
6. SmoothScrollEngine.frame()                       (per render tick)
7.   └── SmoothScrollFrame.offsetPixels             (sub-pixel remainder)
8. TerminalUniformData.scrollOffsetPixels           (uploaded to GPU)
9. terminal_vertex: pixelPos.y += offset            (all cells shift)
```

### Reusing existing patterns
- Animation engine: `CursorRenderer` — target + interpolated render state per frame, `lerp()`, `requiresContinuousFrames()`
- Effect config persistence: `BloomEffectConfiguration.load/save()` pattern
- Uniform struct extension: follow existing padding/alignment in `TerminalUniformData`
- Continuous frame request: existing `needsContinuousFrames` check in DrawLoop
- Settings navigation row: copy pattern from Bloom Glow row in `SettingsView`

### What NOT to do
- Do not apply `scrollOffsetPixels` in NDC space — apply it to `pixelPos` (pixel space) before the NDC division. NDC application creates scaling artifacts on non-square viewports because the Y scale factor includes the aspect ratio
- Do not animate programmatic scrolls (jump-to-bottom, search navigation) — instant jumps feel more responsive for non-user-initiated movement
- Do not make the physics frame-rate-dependent — use `deltaTime` normalization so 60Hz and 120Hz displays produce identical scroll feel
- Do not persist `renderOffset` or `velocity` across app restarts — scroll animation state is ephemeral
- Do not feed trackpad momentum events (`event.momentumPhase != .none`) as raw deltas into the engine — these are macOS's own momentum simulation. When your engine has `momentumEnabled == true`, ignore system momentum events entirely and use your own physics. When `momentumEnabled == false`, pass system momentum through as regular deltas for native-feeling coast
- Do not apply the offset to the post-process pass UV (bloom, CRT, gradient) — the post-process samples from the scene texture which already has shifted pixels baked in from the vertex shader

---

## Verification (end-to-end)

1. Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
2. Run app → open local terminal → `cat /usr/share/dict/words` → scroll up/down with trackpad → observe smooth sub-pixel movement
3. Flick scroll and release → observe momentum coast with deceleration → eventually stops
4. Scroll to top of scrollback → verify no overscroll past beginning
5. SSH to remote host → run `htop` → scroll → verify no interaction with live-updating content
6. Split panes → verify independent smooth scroll per pane
7. Settings → Smooth Scrolling → adjust friction slider → next scroll gesture uses new value
8. System Preferences → Accessibility → Reduce Motion → verify smooth scrolling auto-disables
9. Connect discrete mouse → verify scroll works with fixed step size (no sub-pixel interpolation on discrete mice)
10. Run tests: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
