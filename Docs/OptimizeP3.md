# P3 Optimization — Polish & Minor Wins

Actionable phased checklist for all remaining P3 items from `docs/Optimization.md`.

---

## Phase 0: Demand-Driven Rendering (Idle Power Savings) ✅ DONE

**Goal:** Stop redrawing at 60-120fps when nothing has changed. Switch to on-demand rendering.

**Files:** `MetalTerminalRenderer.swift`, `MetalTerminalRenderer+ViewConfiguration.swift`, `MetalTerminalRenderer+DrawLoop.swift`, `MetalTerminalRenderer+SnapshotUpdate.swift`

- [x] Switched MTKView to demand-driven mode (`enableSetNeedsDisplay = true`, `isPaused = true`)
- [x] Added `requiresContinuousFrames()` aggregating cursor lerp, smooth scroll, scanner effect, gradient animation
- [x] Added `requestFrame()` helper: enables display link for continuous animations, uses `setNeedsDisplay(bounds)` for one-shot updates
- [x] Simplified draw loop pause gate to use `requiresContinuousFrames()`
- [x] Replaced all 4 `isPaused = false` trigger sites with `requestFrame()`
- [x] Effect animations (scanner, gradient) now prevent pausing when active
- [x] Build passes

---

## Phase 1: Performance Monitor — Ring Buffer & Cached Sort ✅ ALREADY DONE

**Status:** Already implemented. `RendererPerformanceMonitor.swift` uses a `RingBuffer` struct
with `storage: [Double]`, `head: Int`, `count_: Int`, O(1) `append()`, no `removeFirst()`.
`percentile()` is only called once per `snapshot()` (infrequent diagnostic reads), so cached
sort has negligible benefit — skipped.

---

## Phase 2: Selection Renderer — Single-Pass & Skip Optimization ✅ ALREADY DONE

**Status:** Already optimized. `SelectionRenderer` uses `needsProjection()` early-exit,
`previousSelectionLinearRange` for targeted clear, and row-scoped iteration. The two-pass
merge and accent color caching provide marginal gains not worth the complexity.

---

## Phase 3: SwiftUI View Layer — Targeted Defaults Observation ✅ ALREADY DONE

**Status:** Already optimized. `reloadRendererSettingsIfNeeded()` caches current values and
compares before applying. The blanket notification fires infrequently and the compare-gate
makes each invocation cheap. Switching to KVO on individual keys adds complexity for
marginal gain.

---

## Phase 4: SwiftUI View Layer — Blur Optimization ✅ DONE

**Goal:** Eliminate hidden GPU cost of blur view when fully opaque.

**Files:** `TerminalMetalView.swift`

- [x] Hide `NSVisualEffectView` when `backgroundOpacity >= 1.0` — `blurView.isHidden = true` removes it from the compositing pipeline entirely
- [x] When opacity < 1.0, blur view is shown and alpha set accordingly
- [x] Closure reassignment in `updateNSView` skipped — retain/release cost is negligible vs blur GPU savings

---

## Phase 5: Shared FontManager ✅ ALREADY DONE (SKIPPED)

**Status:** One `FontManager` allocation per session is negligible impact. The allocation
is lightweight and sessions share the same font settings via UserDefaults. Not worth the
thread-safety complexity of a shared singleton.

---

## Phase 6: OSC Handler — Direct Byte Parsing ✅ ALREADY DONE

**Status:** Already optimized. `parseASCIIInt()` parses OSC codes directly from raw bytes
without intermediate String allocation. String conversion only happens for payloads that
genuinely need it (window titles, hyperlinks).

---

## Phase 7: GridReflow — Trim Trailing Blanks COW Fix ✅ ALREADY DONE

**Status:** Already optimized. `trimTrailingBlanks()` uses `lastIndex(where:)` + single
`Array(prefix(...))` slice. No COW-triggering `var copy` + `removeLast()` loop.

---

## Verification

After all phases:

- [ ] Full build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
- [ ] Full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
- [ ] Power/thermal test: open 3 sessions idle for 60s — measure CPU/GPU usage (Activity Monitor)
- [ ] Manual QA: scroll, select, resize, change fonts, toggle effects, open/close sessions
- [ ] Benchmark: `./scripts/benchmark-throughput.sh --benchmark-bytes 2097152 --benchmark-runs 3 --benchmark-chunk 4096 --no-build`
- [ ] Update `docs/Optimization.md` — check off completed items, record new benchmark numbers
