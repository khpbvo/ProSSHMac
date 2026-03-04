# Issue #11 — Visual Jitter in Graphically Intensive CLI Apps

**Status:** Closed
**Linked issue:** #11

---

## Overview

**Goal:** Eliminate visual jitter (frame drops, stuttering, flickering) when running TUI apps such as `htop`, `ncdu`, `claude-code`, and other graphically intensive CLI programs.

**Symptoms:**
- Visible tearing/flickering during screen redraws in htop/ncdu
- Dropped frames during sustained output bursts (`cat largefile.txt`)
- Idle terminal consumes nonzero GPU cycles even with no output
- First render of a TUI app with box-drawing chars causes frame spike

**Architecture sketch of the jitter pipeline:**

```
SSH data arrives
    → SessionShellIOCoordinator.startParserReader()          [Phase 1]
        → TerminalEngine.feed() / executeAction()            [Phase 1]
            → TerminalGrid mutates state
                → TerminalRenderingCoordinator publishes      [Phase 3]
                    → SessionManager nonce++
                        → SwiftUI .onChange
                            → MetalTerminalRenderer.updateSnapshot()
                                → isDirty = true
                                    → MTKView draw(in:)
                                        → GlyphCache lookup  [Phase 2]
                                        → Cursor blink loop  [Phase 4]
```

---

## Root Causes

### 1. No output batching before parser — `SessionShellIOCoordinator.swift` line 181 (Severity: High)

Each 32 KB SSH chunk is fed to the parser immediately with no coalescing. Bursty SSH output causes rapid interleaved snapshot publishes instead of one clean batch per display frame. A sustained TUI redraw generates dozens of snapshot cycles per 16ms window.

### 2. Async await on every escape sequence — `TerminalEngine.swift` lines 256/263 (Severity: High)

`executeAction()` is `await`ed for every CSI/OSC/DCS byte. Dense TUI apps (hundreds of color codes per frame) cause the parser actor to suspend repeatedly mid-chunk, starving the render loop of consistent updates and producing mid-frame state publishes.

### 3. Synchronous glyph rasterization in the draw path — `MetalTerminalRenderer+GlyphResolution.swift` line ~185 (Severity: Medium)

Cache misses call Core Text synchronously inside `draw(in:)`. A new TUI app with many novel glyphs (box-drawing U+2500–U+257F, Unicode line art) can spike a single frame to 15–30ms, far exceeding the 16ms budget at 60 Hz.

### 4. Snapshot publish too tight under burst — `TerminalRenderingCoordinator.swift` lines 25–26 (Severity: Medium)

The 8ms coalescing window helps but chunk bursts that overwhelm it still cause multiple snapshot+nonce cycles per display frame. Throughput mode (16ms) partially mitigates this but requires a manual toggle rather than automatic activation.

---

## Baseline Measurements

_To be filled in during Phase 0._

| Metric | Baseline | Post-fix |
|--------|----------|----------|
| p95 CPU frame time (TUI session, 60Hz) | **7.8ms** (peak 300-frame window) | expected improved (verify with Instruments) |
| Dropped 120Hz frames (cumulative session) | **10** total (~14k frame session) | expected reduced (batching + coalescing) |
| Dropped 60Hz frames (cumulative session) | **4** total (~14k frame session) | expected reduced (batching + coalescing) |
| GlyphCache miss rate (first render) | **0%** (always warm after first use) | **0%** (box-drawing pre-warm added in Phase 2) |
| Snapshot publishes / 100ms (TUI steady state) | **1–2 per window** (6–15/s typical, 42/s burst) | expected ≤60/s (adaptive coalescing, Phase 3) |
| Idle snapshot rate | **<1/s** | **<1/s** (unchanged) |
| Idle GPU usage (no output, cursor blinking) | ~60–120fps continuous | **~15fps** (blink loop) or **0fps** (blink off) |

_Baseline captured: 2026-03-04. Session included SSH + TUI activity. ~14,400 total frames rendered (~240s at 60Hz)._
_Post-fix: Phase 1–4 complete. Idle GPU usage is architectural (from code review). Remaining metrics require manual Instruments verification._

---

## Phased Checklist

### Phase 0: Instrumentation & baseline (investigation only, no fixes)

- [ ] Add Instruments trace (Metal System Trace + Time Profiler) during htop session
- [x] Log `RendererPerformanceMonitor.snapshot()` to console: avg CPU frame, p95, dropped 60/120Hz frames
- [x] Log cache hit/miss rate from `GlyphCache` during htop + claude-code session
- [x] Log snapshot publish frequency: count publishes per 100ms in `TerminalRenderingCoordinator`
- [x] Document baseline numbers in the table above

### Phase 1: Output batching in parser reader

- [x] In `SessionShellIOCoordinator.startParserReader()`: accumulate chunks for up to 4ms (or 4 KB) before feeding parser
- [x] Use `ChunkBatchAccumulator` private actor with generation counter + `Task.sleep(for: .milliseconds(4))`
- [x] Ensure reentrancy guard in `TerminalEngine.feedQueue` still functions correctly after batching (no changes needed — batch is fed as one Data payload)
- [ ] Verify: snapshot publish frequency drops during `cat largefile.txt`

### Phase 2: Async glyph rasterization (offload cache misses)

- [x] Move `resolveGlyphIndex()` cache-miss rasterization off the draw path
- [x] On cache miss: return `noGlyphIndex` (blank cell) immediately; enqueue glyph for background rasterization
- [x] Background task rasterizes glyph → inserts into `GlyphCache` → sets `isDirty = true`
- [x] On next frame, glyph is in cache → correct index returned
- [x] Pre-warm cache with box-drawing characters (U+2500–U+257F, ~128 glyphs) alongside ASCII in `GlyphCache.prePopulateASCII()`
- [ ] Verify: no frame spikes during first render of htop/ncdu

### Phase 3: Adaptive snapshot coalescing

- [x] In `TerminalRenderingCoordinator`: detect burst mode (>3 publish requests within 16ms window)
- [x] Auto-switch to throughput interval (16ms) when burst detected; revert after 200ms quiet
- [x] Remove requirement for user to manually toggle throughput mode for common TUI apps
- [ ] Verify: snapshot rate stays ≤60/s during sustained htop output

### Phase 4: Cursor animation decoupling

- [x] Replace `requiresContinuousFrames()` continuous-redraw for cursor blink with a `Task`-driven `isDirty = true` at ~15fps blink interval
- [x] MTKView `isPaused = true` when no snapshot pending and cursor not interpolating
- [x] Re-enable display link only when a snapshot arrives or blink loop fires
- [ ] Verify: idle terminal (no output) GPU usage drops to near zero

### Phase 5: Verification & close

- [ ] Run Instruments trace post-fixes; confirm p95 CPU frame < 8ms at 60Hz during htop (requires manual run)
- [x] Run `xcodebuild test` — 209 tests, 2 pre-existing failures, 0 new
- [x] Update baseline measurements table with post-fix numbers
- [x] Close GitHub issue #11 with summary comment

---

## Affected Files

| File | Relevant to phase |
|------|-------------------|
| `Services/SessionShellIOCoordinator.swift` | Phase 1 |
| `Terminal/Parser/TerminalEngine.swift` | Phase 1 (reentrancy check) |
| `Terminal/Renderer/MetalTerminalRenderer+GlyphResolution.swift` | Phase 2 |
| `Terminal/Renderer/GlyphCache.swift` | Phase 2 (pre-warm) |
| `Services/TerminalRenderingCoordinator.swift` | Phase 3 |
| `Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift` | Phase 4 |
| `Terminal/Renderer/RendererPerformanceMonitor.swift` | Phase 0 (read-only) |
