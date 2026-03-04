# TextGlow — Bloom / Text Glow Effect

## Overview

Add a GPU multi-pass bloom effect to ProSSHMac's Metal terminal renderer. Bright terminal text
(bold colors from htop, syntax highlighting, ANSI bright palette) gets a soft glow halo — giving
the terminal a holographic/neon aesthetic. The bloom optionally pulses with the gradient background
animation system.

### Goal
Implement a real bloom pipeline: bright-pass extraction → downsample → separable Gaussian blur
(H + V passes) → additive composite back into the post-process pass.

### Architecture Sketch

```
[Scene render] → postProcessTexture (existing)
                       │
                  [Bright-pass]  ← new: sample postProcessTexture, extract luminant pixels
                       │
                  bloomBrightTexture (half-res)
                       │
                  [Blur H-pass]  ← new: separable Gaussian, horizontal
                       │
                  bloomBlurH (half-res)
                       │
                  [Blur V-pass]  ← new: separable Gaussian, vertical
                       │
                  bloomBlurV (half-res)
                       │
                  [Post-process pass] (existing terminal_post_fragment)
                    └── additively blends bloomBlurV + existing effects (CRT, gradient, scanlines)
```

### Affected Files

| File | Change |
|---|---|
| `Terminal/Renderer/TerminalShaders.metal` | New shader functions: `bloom_bright_fragment`, `bloom_blur_fragment` (H+V), modified `terminal_post_fragment` |
| `Terminal/Renderer/MetalTerminalRenderer.swift` | New pipeline states: bright, blurH, blurV |
| `Terminal/Renderer/MetalTerminalRenderer+PostProcessing.swift` | New textures, `ensureBloomTextures()`, bloom uniform upload |
| `Terminal/Renderer/MetalTerminalRenderer+DrawLoop.swift` | Insert 3 bloom passes before post-process when bloom enabled |
| `Terminal/Renderer/TerminalUniforms.swift` | New bloom fields in `TerminalUniformData` + `TerminalUniformBuffer.update()` |
| `Terminal/Effects/BloomEffect.swift` | New: `BloomEffectConfiguration` struct, UserDefaults persistence |
| `UI/Settings/BloomEffectSettingsView.swift` | New: settings sub-view |
| `UI/Settings/SettingsView.swift` | Add bloom row |

---

## Phased Checklist

### - [x] Phase 0: Configuration & Uniforms

**Goal:** Lay the data foundation — config struct, persistence, uniform fields — before touching Metal.

**Tasks:**
- Create `Terminal/Effects/BloomEffect.swift`:
  - `BloomEffectConfiguration: Codable, Equatable` with fields:
    - `isEnabled: Bool` (default: `false`)
    - `threshold: Float` (default: `0.45`) — luminance above which pixels bloom
    - `intensity: Float` (default: `0.65`) — additive blend strength
    - `radius: Float` (default: `1.5`) — controls Gaussian blur sigma (mapped to 9–13 tap kernel)
    - `animateWithGradient: Bool` (default: `true`) — pulse with gradient animation
  - `static func load(from: UserDefaults) -> BloomEffectConfiguration`
  - `func save(to: UserDefaults)` — key: `"terminal.effects.bloom"`
  - `static let `default`: BloomEffectConfiguration`
- Add to `TerminalUniformData` (in `TerminalUniforms.swift`):
  - `bloomEnabled: UInt32`
  - `bloomThreshold: Float`
  - `bloomIntensity: Float`
  - `bloomAnimateWithGradient: UInt32`
  - (Keep Metal struct 16-byte aligned — add padding if needed)
- Wire in `TerminalUniformBuffer.update()`:
  - Load `BloomEffectConfiguration.load(from: .standard)`
  - Set uniform fields; pulse `bloomIntensity` by `sin(time)` when `animateWithGradient && gradientAnimationMode != .none`
- Verify: `xcodebuild build` — no compiler errors. No visual change yet.

---

### - [x] Phase 1: Textures & Pipeline States

**Goal:** Allocate GPU resources and register shader entry points. Shaders are stubs (passthrough) — no visual change yet.

**Tasks:**
- In `MetalTerminalRenderer+PostProcessing.swift`:
  - Add `bloomBrightTexture: MTLTexture?`, `bloomBlurH: MTLTexture?`, `bloomBlurV: MTLTexture?`
  - Add `ensureBloomTextures(width:height:device:)`:
    - Allocate all three at **half resolution** (`width/2 × height/2`, `.bgra8Unorm`, `.renderTarget | .shaderRead`)
    - Reallocate when `drawableSize` changes (same resize guard pattern as `ensurePostProcessTextures`)
    - Guard: only allocate when `bloomEnabled`; nil-out textures when disabled
  - Call `ensureBloomTextures` from the existing `ensurePostProcessTextures` codepath
- In `MetalTerminalRenderer.swift`:
  - Add pipeline states: `bloomBrightPipeline`, `bloomBlurHPipeline`, `bloomBlurVPipeline` (all `MTLRenderPipelineState?`)
  - Create in `buildPipelines()` using stub shader functions (`bloom_bright_vertex/fragment`, `bloom_blur_vertex/fragment`)
  - Pixel format: `.bgra8Unorm` (matching bloom textures)
- In `TerminalShaders.metal`:
  - Add **stub** vertex function `bloom_bright_vertex` (same full-screen triangle as `terminal_post_vertex`)
  - Add **stub** fragment function `bloom_bright_fragment` — returns `float4(0)` (black)
  - Add **stub** functions `bloom_blur_vertex`, `bloom_blur_fragment` — returns `float4(0)`
- Verify: `xcodebuild build`. No visual change, no crash.

---

### - [x] Phase 2: Bright-Pass Shader

**Goal:** Extract luminant pixels from the scene texture into `bloomBrightTexture`.

**Tasks:**
- In `TerminalShaders.metal`, implement `bloom_bright_fragment`:
  ```metal
  float4 bloom_bright_fragment(PostVertexOut in [[stage_in]],
                                texture2d<float> sceneTexture [[texture(0)]],
                                constant TerminalUniforms& uniforms [[buffer(1)]]) {
      float4 color = sceneTexture.sample(linearSampler, in.texCoord);
      float lum = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
      // Knee function: smooth extraction above threshold
      float bright = max(0.0, lum - uniforms.bloomThreshold)
                     / max(0.001, 1.0 - uniforms.bloomThreshold);
      bright = bright * bright;   // square for sharper knee
      return float4(color.rgb * bright, 1.0);
  }
  ```
- In `MetalTerminalRenderer+DrawLoop.swift`, add bright-pass encoding method `encodeBrightPass(commandBuffer:)`:
  - Guard: `bloomEnabled && bloomBrightTexture != nil && postProcessTexture != nil`
  - Render pass: target `bloomBrightTexture`, load `.dontCare`, store `.store`
  - Draw full-screen triangle using `bloomBrightPipeline`
  - Bind `postProcessTexture` as `texture(0)`, uniform buffer as `buffer(1)`
- Call `encodeBrightPass` in `draw(in:)` **after** the scene pass, **before** the post-process pass
- Verify: enable bloom in code temporarily; `bloomBrightTexture` should contain only bright-colored terminal pixels (can verify with GPU debugger in Xcode). Build must pass.

---

### - [x] Phase 3: Separable Gaussian Blur (H + V Passes)

**Goal:** Blur the bright texture with a two-pass separable Gaussian kernel.

**Tasks:**
- Add constant to `TerminalShaders.metal`:
  ```metal
  constant int BLOOM_KERNEL_HALF = 6;   // 13-tap kernel
  constant float BLOOM_WEIGHTS[7] = { 0.227027, 0.1945946, 0.1216216,
                                       0.054054, 0.016216, 0.003784, 0.000541 };
  ```
- Implement `bloom_blur_fragment` (single function, parameterized by a `bool horizontal` uniform or a separate constant buffer):
  ```metal
  // texelSize = float2(1.0/width, 1.0/height) of the bloom texture
  float4 bloom_blur_fragment(PostVertexOut in [[stage_in]],
                              texture2d<float> blurInput [[texture(0)]],
                              constant TerminalUniforms& u [[buffer(1)]]) {
      float2 ts = float2(1.0 / u.bloomTexelWidth, 1.0 / u.bloomTexelHeight);
      float3 result = blurInput.sample(linearSampler, in.texCoord).rgb * BLOOM_WEIGHTS[0];
      float2 dir = (u.bloomBlurHorizontal > 0.5) ? float2(ts.x, 0) : float2(0, ts.y);
      for (int i = 1; i <= BLOOM_KERNEL_HALF; i++) {
          result += blurInput.sample(linearSampler, in.texCoord + dir * float(i)).rgb * BLOOM_WEIGHTS[i];
          result += blurInput.sample(linearSampler, in.texCoord - dir * float(i)).rgb * BLOOM_WEIGHTS[i];
      }
      return float4(result * u.bloomRadius, 1.0);
  }
  ```
  - Add `bloomTexelWidth: Float`, `bloomTexelHeight: Float`, `bloomBlurHorizontal: Float`, `bloomRadius: Float` to `TerminalUniformData`
  - Wire in `TerminalUniformBuffer.update()`
- In `MetalTerminalRenderer+DrawLoop.swift`, add `encodeBlurPasses(commandBuffer:)`:
  - H-pass: target `bloomBlurH`, input `bloomBrightTexture`, set `bloomBlurHorizontal = 1.0`
  - V-pass: target `bloomBlurV`, input `bloomBlurH`, set `bloomBlurHorizontal = 0.0`
  - Both use `bloomBlurHPipeline` (reuse same pipeline, direction controlled by uniform)
- Call `encodeBlurPasses` after `encodeBrightPass`
- Verify: in Xcode GPU debugger, `bloomBlurV` should show a soft blurred halo of the bright terminal text.

---

### - [x] Phase 4: Composite Bloom into Post-Process Pass

**Goal:** Additively blend `bloomBlurV` into the final frame. First visible result.

**Tasks:**
- In `TerminalShaders.metal`, modify `terminal_post_fragment`:
  - Add new texture parameter: `texture2d<float> bloomTexture [[texture(2)]]`
  - After the scene sample (and before gradient/background compositing), insert:
    ```metal
    if (uniforms.bloomEnabled > 0.5) {
        // upsample from half-res to full-res (bilinear via linear sampler — free)
        float3 bloomColor = bloomTexture.sample(linearSampler, uv).rgb;
        color.rgb += bloomColor * uniforms.bloomIntensity;
        color.rgb = saturate(color.rgb);
    }
    ```
  - Insert this **before** gradient compositing so gradient can tint over bloom if desired
- In `MetalTerminalRenderer+DrawLoop.swift`, bind `bloomBlurV` as `texture(2)` in the post-process encoder:
  - Guard: bind `crtFallbackTexture` (1×1 black) when bloom is disabled, so the texture slot is never nil
- Enable bloom by default in `BloomEffectConfiguration` temporarily to test visually
- Verify: bold/colored terminal text (run `htop` or `ls --color`) should show a soft glow halo around bright characters.

---

### - [x] Phase 5: Gradient Animation Coupling

**Goal:** Make bloom respond to the gradient background animation system.

**Tasks:**
- In `TerminalUniformBuffer.update()`:
  - When `bloomAnimateWithGradient == 1 && gradientEnabled && gradientAnimationMode != .none`:
    - Pulse: `effectiveBloomIntensity = bloomIntensity * (0.85 + 0.15 * sin(time * gradientAnimationSpeed * 1.5))`
    - Upload `effectiveBloomIntensity` instead of raw `bloomIntensity`
  - When gradient animation mode is `.aurora` or `.wave`, add a subtle radius pulse:
    - `effectiveRadius = bloomRadius * (0.9 + 0.1 * cos(time * gradientAnimationSpeed))`
- In `terminal_post_fragment`, optionally tint bloom halo toward the gradient's dominant color:
  ```metal
  if (uniforms.bloomEnabled > 0.5 && uniforms.gradientEnabled > 0.5
      && uniforms.bloomAnimateWithGradient > 0.5) {
      float3 gradHint = computeGradientColor(uv, uniforms).rgb * 0.25;
      float3 bloomColor = bloomTexture.sample(linearSampler, uv).rgb;
      color.rgb += (bloomColor + gradHint * length(bloomColor)) * uniforms.bloomIntensity;
  }
  ```
  - The `gradHint` term tints bloom toward the gradient color proportional to bloom brightness
- Verify: with gradient enabled in `breathe` mode, bloom halo should pulse in sync. With `aurora` mode, halo should subtly shift color.

---

### - [x] Phase 6: Settings UI

**Goal:** Expose bloom as a user-configurable effect in Settings, consistent with existing effects UX.

**Tasks:**
- Create `UI/Settings/BloomEffectSettingsView.swift`:
  ```
  BloomEffectSettingsView
  ├── Toggle "Enable Bloom Glow"
  ├── (when enabled) Section "Bloom Settings"
  │     ├── Slider "Threshold" (0.2–0.8, step 0.05) — label: "Brightness cutoff"
  │     │     subtitle: "Lower = more text glows"
  │     ├── Slider "Intensity" (0.1–1.5, step 0.05) — label: "Glow strength"
  │     ├── Slider "Radius" (0.5–3.0, step 0.25) — label: "Blur radius"
  │     └── Toggle "Animate with Gradient" — only shown when gradient is enabled
  └── (when enabled) Preview area
        └── Static MTKView snapshot or animated GradientPreviewRenderer showing bloom effect
  ```
  - On any change: call `config.save(to: .standard)` + post `Notification` or use `@Published` pattern (follow existing `GradientBackgroundSettingsView` pattern)
  - The renderer picks up changes next frame via `BloomEffectConfiguration.load()` in `TerminalUniformBuffer.update()`
- In `UI/Settings/SettingsView.swift`:
  - Add row below Scanner Effect:
    ```swift
    NavigationLink(destination: BloomEffectSettingsView()) {
        HStack {
            Label("Bloom Glow", systemImage: "sparkles")
            Spacer()
            if BloomEffectConfiguration.load(from: .standard).isEnabled {
                Text("On").foregroundColor(.purple)
            }
        }
    }
    ```
- Verify: settings navigation works, values persist across app restarts, renderer reacts within one frame.

---

### - [x] Phase 7: QA, Performance & Polish

**Goal:** Validate correctness, measure GPU overhead, handle edge cases.

**Tasks:**
- Performance profiling with Instruments (Metal System Trace):
  - Measure GPU frame time with bloom enabled vs disabled at 60Hz and 120Hz
  - Target: bloom adds < 0.5ms GPU time at 60Hz on Apple Silicon
  - If over budget: switch to quarter-resolution blur textures or reduce to 9-tap kernel
- Edge cases:
  - Window resize: bloom textures reallocate correctly, no stale-size blur artifact
  - Font change: bloom continues to work (bloom is scene-texture based, font-agnostic)
  - Window minimize / background: `MTKView` pauses naturally, no bloom pass runs
  - External display (HiDPI): verify `drawableSize` scaling is applied to bloom texture allocation
  - Bloom disabled: confirm `bloomBrightTexture`, `bloomBlurH`, `bloomBlurV` are `nil` and not allocated
  - Post-process disabled: bloom should force post-process path active (add `bloomEnabled` to the `needsPostProcess` check in `DrawLoop`)
- Run full test suite: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
- Update `docs/featurelist.md` with dated entry
- Update `CLAUDE.md` if new key files or architecture conventions were added
- Commit all changes

---

## Key Architecture Notes

### Render pass insertion order (final)
```
1. Scene pass           → postProcessTexture        (existing)
2. Bright-pass          → bloomBrightTexture (½-res) (NEW)
3. Blur H-pass          → bloomBlurH (½-res)         (NEW)
4. Blur V-pass          → bloomBlurV (½-res)          (NEW)
5. Post-process pass    → drawable                    (existing, modified)
   └── blends bloomBlurV additively before CRT/gradient
6. Blit                 → previousFrameTexture        (existing)
```

### Reusing existing patterns
- Texture allocation pattern: `ensurePostProcessTextures()` in `MetalTerminalRenderer+PostProcessing.swift`
- Full-screen triangle shader: `terminal_post_vertex` — reuse as `bloom_bright_vertex` and `bloom_blur_vertex`
- Pipeline state creation: `buildPipelines()` in `MetalTerminalRenderer.swift`
- Uniform update pattern: `TerminalUniformBuffer.update()` in `TerminalUniforms.swift`
- Effect config persistence: `GradientBackgroundConfiguration.load/save()` pattern
- Settings navigation row: copy pattern from Scanner Effect row in `SettingsView`

### What NOT to do
- Do not apply bloom to the cursor glow area (the analytic cursor glow is already brighter than the bloom threshold — they stack naturally)
- Do not run bloom passes when `bloomEnabled == false` (even the pipeline bind should be skipped to save CPU)
- Do not allocate full-resolution bloom textures — half-res is sufficient and cuts memory/bandwidth by 4×
- Do not add bloom as a per-cell attribute — it's a screen-space post-process, not per-cell

---

## Verification (end-to-end)

1. Build: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' build`
2. Run app → SSH into a host → run `htop` → enable Bloom in Settings → observe colored text glowing
3. Enable gradient background with `aurora` animation → observe bloom halo subtly shifting color in sync
4. Open Xcode GPU Debugger → capture frame → verify 4 render passes + 1 blit exist when bloom+postprocess active
5. Run tests: `xcodebuild -scheme ProSSHMac -destination 'platform=macOS' test`
6. Profile with Instruments → confirm bloom < 0.5ms GPU frame overhead
