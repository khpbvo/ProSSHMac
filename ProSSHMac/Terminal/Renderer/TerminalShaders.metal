// TerminalShaders.metal
// ProSSHV2
//
// Metal shaders for GPU-accelerated terminal rendering.
// Implements instanced quad rendering where each cell is one instance,
// with glyph atlas sampling, attribute handling, cursor rendering,
// selection overlay, and text decoration effects.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

/// Attribute bit positions — must match CellAttributes in TerminalCell.swift.
// ATTR_BOLD (1u << 0) — handled by glyph rasterizer, not used in shader
constant uint ATTR_DIM           = (1u << 1);
// constant uint ATTR_ITALIC     = (1u << 2);  // handled by glyph rasterizer
constant uint ATTR_UNDERLINE     = (1u << 3);
constant uint ATTR_BLINK         = (1u << 4);
constant uint ATTR_REVERSE       = (1u << 5);
constant uint ATTR_HIDDEN        = (1u << 6);
constant uint ATTR_STRIKETHROUGH = (1u << 7);
constant uint ATTR_DOUBLE_UNDER  = (1u << 8);
// constant uint ATTR_WIDE_CHAR  = (1u << 9);  // layout only
// constant uint ATTR_WRAPPED    = (1u << 10); // layout only
constant uint ATTR_OVERLINE      = (1u << 11);

/// Flag bit positions — must match CellInstance flags in GridSnapshot.swift.
constant uint8_t FLAG_SELECTED = (1u << 2);

/// Cursor style values — must match CursorStyle in VTConstants.swift.
constant uint CURSOR_BLOCK     = 0;
constant uint CURSOR_UNDERLINE = 1;
constant uint CURSOR_BAR       = 2;

/// Sentinel glyph index value meaning "no glyph".
constant uint GLYPH_INDEX_NONE = 0xFFFFFFFFu;

/// Decoration geometry constants.
constant float UNDERLINE_THICKNESS  = 1.0;
constant float STRIKETHROUGH_THICKNESS = 1.0;
constant float DOUBLE_UNDER_GAP     = 2.0;
constant float OVERLINE_THICKNESS   = 1.0;
constant float CURSOR_BAR_WIDTH     = 2.0;
constant float CURSOR_UNDERLINE_HEIGHT = 2.0;

/// Underline style constants — must match UnderlineStyle in VTConstants.swift.
constant uint8_t UL_STYLE_NONE   = 0;
constant uint8_t UL_STYLE_SINGLE = 1;
constant uint8_t UL_STYLE_DOUBLE = 2;
constant uint8_t UL_STYLE_CURLY  = 3;
constant uint8_t UL_STYLE_DOTTED = 4;
constant uint8_t UL_STYLE_DASHED = 5;

/// Curly underline wave parameters.
constant float CURLY_AMPLITUDE   = 2.0;  // wave height in pixels
constant float CURLY_FREQUENCY   = 0.5;  // wave periods per cell width

/// Cursor glow parameters.
constant float GLOW_RADIUS   = 3.0;   // cells of influence
constant float GLOW_STRENGTH = 0.12;  // max glow alpha

// ---------------------------------------------------------------------------
// MARK: - Structs (B.5.1, B.5.2)
// ---------------------------------------------------------------------------

/// GPU-ready cell instance — mirrors Swift CellInstance layout exactly.
struct CellInstance {
    ushort  row;            // grid row
    ushort  col;            // grid column
    uint    glyphIndex;     // atlas position: upper 16 bits = Y, lower 16 bits = X
    uint    fgColor;        // packed RGBA (R in high byte)
    uint    bgColor;        // packed RGBA (R in high byte)
    uint    underlineColor; // packed RGBA for underline (0 = use fgColor)
    ushort  attributes;     // CellAttributes bitfield
    uint8_t flags;          // bit 0=dirty, bit 1=cursor, bit 2=selected
    uint8_t underlineStyle; // 0=none, 1=single, 2=double, 3=curly, 4=dotted, 5=dashed
};

/// Per-frame uniforms set by the CPU.
struct TerminalUniforms {
    float2 cellSize;       // pixel dimensions of one cell
    float2 viewportSize;   // total viewport in pixels
    float2 atlasSize;      // glyph atlas texture dimensions
    float  time;           // seconds, for animated effects
    float  cursorPhase;    // 0.0–1.0 blink visibility phase
    float  cursorRenderRow; // fractional row position for smooth cursor animation
    float  cursorRenderCol; // fractional col position for smooth cursor animation
    uint   cursorStyle;    // 0=block, 1=underline, 2=bar
    float  cursorVisible;  // 1.0 = app-visible (DECTCEM), 0.0 = app-hidden
    float  selectionAlpha; // selection highlight opacity
    float  dimOpacity;     // opacity multiplier for SGR dim attribute
    float  glowIntensity;  // cursor glow strength scalar
    float  crtEnabled;     // 1.0 = CRT effects enabled
    float  scanlineOpacity; // scanline darkening opacity
    float  scanlineDensity; // scanline frequency scalar
    float  barrelDistortion; // NDC barrel warp strength
    float  phosphorBlend;  // previous-frame phosphor contribution
    float  contentScale;   // screen scale factor (1.0 = 1x, 2.0 = Retina)
    float4 selectionColor; // selection tint

    // -- Gradient Background Effect --
    float  gradientEnabled;           // 1.0 = gradient background on
    uint   gradientStyle;             // 0=linear, 1=radial, 2=angular, 3=diamond, 4=mesh
    float  _gradientAlignPad0;        // alignment padding
    float  _gradientAlignPad1;        // alignment padding
    float4 gradientColor1;            // primary color (RGBA)
    float4 gradientColor2;            // secondary color (RGBA)
    float4 gradientColor3;            // tertiary color (RGBA)
    float4 gradientColor4;            // quaternary color (RGBA)
    float  gradientUseMultipleStops;  // 1.0 = use color3/color4
    float  gradientAngle;             // angle in radians
    uint   gradientAnimationMode;     // 0=none,1=breathe,2=shift,3=wave,4=aurora
    float  gradientAnimationSpeed;    // speed multiplier
    float  gradientGlowIntensity;     // glow strength (0–1)
    float  _gradientAlignPad2;        // alignment padding
    float  _gradientAlignPad3;        // alignment padding
    float  _gradientAlignPad4;        // alignment padding
    float4 gradientGlowColor;         // glow tint (RGBA)
    float  gradientGlowRadius;        // glow radius as viewport fraction
    float  gradientNoiseIntensity;    // film grain (0–1)
    float  gradientVignetteIntensity; // edge darkening (0–1)
    float  gradientCellBlendOpacity;  // cell bg transparency to gradient (0–1)
    float  gradientSaturation;        // saturation multiplier
    float  gradientBrightness;        // brightness offset
    float  gradientContrast;          // contrast multiplier
    float  _gradientPad;              // alignment padding

    // -- Scanner (Knight Rider) Effect --
    float  scannerEnabled;            // 1.0 = scanner glow active
    float  scannerSpeed;              // sweep speed multiplier
    float  scannerGlowWidth;          // glow width as fraction of username span
    float  scannerIntensity;          // glow brightness
    float4 scannerColor;              // glow color (RGBA)
    float  scannerUsernameLen;        // number of username characters
    float  scannerTrailLength;        // trailing tail length
    float  _scannerPad0;             // alignment padding
    float  _scannerPad1;             // alignment padding
};

/// Vertex-to-fragment interpolants.
struct VertexOut {
    float4 position [[position]];  // clip-space position
    float2 uv;                     // glyph atlas UV
    float2 cellUV;                 // local UV within the cell [0,1]
    uint   fgColor;                // packed fg RGBA
    uint   bgColor;                // packed bg RGBA
    uint   underlineColor;         // packed underline RGBA (0 = use fg)
    uint   glyphIndex;             // packed atlas position or GLYPH_INDEX_NONE
    uint   attributes;             // attribute bitfield
    uint8_t flags;                 // cell flags
    uint8_t underlineStyle;        // underline style enum
    float2 cellPixelPos;           // pixel position of cell origin (top-left)
};

// ---------------------------------------------------------------------------
// MARK: - Utility Functions
// ---------------------------------------------------------------------------

/// Unpack a UInt32 RGBA color (R in bits 31-24) to float4.
inline float4 unpackColor(uint packed) {
    float r = float((packed >> 24) & 0xFF) / 255.0;
    float g = float((packed >> 16) & 0xFF) / 255.0;
    float b = float((packed >>  8) & 0xFF) / 255.0;
    float a = float((packed      ) & 0xFF) / 255.0;
    return float4(r, g, b, a);
}

/// Gaussian falloff for cursor glow effect.
inline float gaussianFalloff(float dist, float sigma) {
    return exp(-(dist * dist) / (2.0 * sigma * sigma));
}

// ---------------------------------------------------------------------------
// MARK: - Vertex Shader (B.5.3)
// ---------------------------------------------------------------------------

/// Instanced vertex shader: 6 vertices per instance form a quad for one cell.
/// Positions the quad at (col, row) * cellSize and transforms to NDC.
vertex VertexOut terminal_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant CellInstance *cells [[buffer(0)]],
    constant TerminalUniforms &uniforms [[buffer(1)]]
) {
    // Fetch the cell for this instance.
    CellInstance cell = cells[iid];

    // Quad corners: two triangles forming a rectangle.
    //   v0--v1     Triangle 0: v0, v1, v2
    //   | / |      Triangle 1: v2, v1, v3
    //   v2--v3
    //
    // vertex_id mapping: 0=v0, 1=v1, 2=v2, 3=v2, 4=v1, 5=v3
    float2 corners[6] = {
        float2(0.0, 0.0),  // v0: top-left
        float2(1.0, 0.0),  // v1: top-right
        float2(0.0, 1.0),  // v2: bottom-left
        float2(0.0, 1.0),  // v2: bottom-left
        float2(1.0, 0.0),  // v1: top-right
        float2(1.0, 1.0),  // v3: bottom-right
    };

    // Bounds-check vid to prevent out-of-bounds access into corners array.
    float2 corner = corners[min(vid, 5u)];

    // Cell origin in pixels (top-left corner of this cell).
    float2 cellOrigin = float2(float(cell.col), float(cell.row)) * uniforms.cellSize;

    // Vertex position in pixels.
    float2 pixelPos = cellOrigin + corner * uniforms.cellSize;

    // Transform to Metal NDC: x in [-1,1], y in [-1,1].
    // Metal clip space: (-1,-1) is bottom-left, (1,1) is top-right.
    // Our pixel space: (0,0) is top-left.
    float2 ndc;
    ndc.x = (pixelPos.x / uniforms.viewportSize.x) *  2.0 - 1.0;
    ndc.y = (pixelPos.y / uniforms.viewportSize.y) * -2.0 + 1.0;

    // Glyph atlas UV coordinates.
    // When glyphIndex is GLYPH_INDEX_NONE, output zero UV so the fragment
    // shader does not sample arbitrary atlas texels.
    float2 uv;
    if (cell.glyphIndex == GLYPH_INDEX_NONE) {
        uv = float2(0.0, 0.0);
    } else {
        // glyphIndex encodes atlas pixel position: upper 16 bits = Y, lower 16 bits = X.
        float atlasX = float(cell.glyphIndex & 0xFFFF);
        float atlasY = float((cell.glyphIndex >> 16) & 0xFFFF);

        float2 uvOrigin = float2(atlasX, atlasY) / uniforms.atlasSize;
        float2 uvSize   = uniforms.cellSize / uniforms.atlasSize;
        uv = uvOrigin + corner * uvSize;
    }

    // Build output.
    VertexOut out;
    out.position       = float4(ndc, 0.0, 1.0);
    out.uv             = uv;
    out.cellUV         = corner;
    out.fgColor        = cell.fgColor;
    out.bgColor        = cell.bgColor;
    out.underlineColor = cell.underlineColor;
    out.glyphIndex     = cell.glyphIndex;
    out.attributes     = uint(cell.attributes);
    out.flags          = cell.flags;
    out.underlineStyle = cell.underlineStyle;
    out.cellPixelPos   = cellOrigin;

    return out;
}

// ---------------------------------------------------------------------------
// MARK: - Fragment Shader (B.5.4 – B.5.11)
// ---------------------------------------------------------------------------

/// Fragment shader: composites glyph, background, attributes, cursor,
/// selection overlay, and text decorations.
fragment float4 terminal_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    texture2d<float> previousFrame [[texture(1)]],
    constant TerminalUniforms &uniforms [[buffer(1)]]
) {
    // -------------------------------------------------------------------
    // 1. Unpack colors
    // -------------------------------------------------------------------
    float4 fg = unpackColor(in.fgColor);
    float4 bg = unpackColor(in.bgColor);

    // Use opaque black as fallback for zero-alpha bg (default terminal bg).
    if (bg.a < 0.001) {
        bg = float4(0.0, 0.0, 0.0, 1.0);
    }
    // Use opaque white as fallback for zero-alpha fg (default terminal fg).
    if (fg.a < 0.001) {
        fg = float4(1.0, 1.0, 1.0, 1.0);
    }

    uint attrs = in.attributes;

    // -------------------------------------------------------------------
    // B.5.5: Reverse attribute — swap fg and bg
    // -------------------------------------------------------------------
    if (attrs & ATTR_REVERSE) {
        float4 tmp = fg;
        fg = bg;
        bg = tmp;
    }

    // -------------------------------------------------------------------
    // B.5.5: Dim attribute — reduce fg brightness
    // -------------------------------------------------------------------
    if (attrs & ATTR_DIM) {
        fg.rgb *= uniforms.dimOpacity;
    }

    // -------------------------------------------------------------------
    // B.5.5: Blink attribute — time-based visibility toggle
    // -------------------------------------------------------------------
    bool blinkHidden = false;
    if (attrs & ATTR_BLINK) {
        // Use a sine wave for smooth blink: visible when sin > 0.
        float blinkWave = sin(uniforms.time * M_PI_F);
        blinkHidden = (blinkWave < 0.0);
    }

    // -------------------------------------------------------------------
    // B.5.5: Hidden attribute — render only background
    // -------------------------------------------------------------------
    bool isHidden = (attrs & ATTR_HIDDEN) != 0;

    // -------------------------------------------------------------------
    // 2. Sample glyph atlas
    // -------------------------------------------------------------------
    constexpr sampler atlasSampler(
        mag_filter::nearest,
        min_filter::nearest,
        address::clamp_to_zero
    );

    float glyphAlpha = 0.0;
    if (in.glyphIndex != GLYPH_INDEX_NONE) {
        float4 glyphSample = atlas.sample(atlasSampler, in.uv);
        glyphAlpha = glyphSample.a;
    }

    // -------------------------------------------------------------------
    // 3. Compose base color: blend fg over bg using glyph coverage
    // -------------------------------------------------------------------
    float4 color;
    if (isHidden || blinkHidden) {
        // Hidden or blink-off: show only background.
        color = bg;
    } else {
        // Standard alpha blend: fg over bg weighted by glyph alpha.
        color.rgb = mix(bg.rgb, fg.rgb, glyphAlpha);
        color.a   = 1.0;
    }

    // -------------------------------------------------------------------
    // B.5.9: Underline rendering — style-aware (single, double, curly, dotted, dashed)
    // Uses underline color when specified, otherwise falls back to fg color.
    // -------------------------------------------------------------------
    {
        uint8_t ulStyle = in.underlineStyle;
        // Also check attribute bits for backward-compat: ATTR_UNDERLINE and ATTR_DOUBLE_UNDER
        // set the style if the per-cell underlineStyle wasn't already set.
        if (ulStyle == UL_STYLE_NONE && (attrs & ATTR_UNDERLINE)) {
            ulStyle = UL_STYLE_SINGLE;
        }
        if (ulStyle == UL_STYLE_NONE && (attrs & ATTR_DOUBLE_UNDER)) {
            ulStyle = UL_STYLE_DOUBLE;
        }

        if (ulStyle != UL_STYLE_NONE && !isHidden && !blinkHidden) {
            // Determine underline draw color
            float3 ulColor;
            if (in.underlineColor != 0) {
                ulColor = unpackColor(in.underlineColor).rgb;
            } else {
                ulColor = fg.rgb;
            }

            float pixelY = in.cellUV.y * uniforms.cellSize.y;
            float pixelX = in.cellUV.x * uniforms.cellSize.x;
            float bottomEdge = uniforms.cellSize.y;
            float scaledThick = UNDERLINE_THICKNESS * uniforms.contentScale;

            if (ulStyle == UL_STYLE_SINGLE) {
                // Single underline: 1px line at bottom
                if (pixelY >= (bottomEdge - scaledThick)) {
                    color.rgb = ulColor;
                }
            } else if (ulStyle == UL_STYLE_DOUBLE) {
                // Double underline: two 1px lines with a gap
                float scaledGap = DOUBLE_UNDER_GAP * uniforms.contentScale;
                float line1Start = bottomEdge - scaledThick;
                float line2Start = bottomEdge - scaledThick - scaledGap - scaledThick;
                float line2End   = line2Start + scaledThick;
                if (pixelY >= line1Start ||
                    (pixelY >= line2Start && pixelY < line2End)) {
                    color.rgb = ulColor;
                }
            } else if (ulStyle == UL_STYLE_CURLY) {
                // Curly underline: sine wave at bottom of cell
                float waveCenter = bottomEdge - CURLY_AMPLITUDE * uniforms.contentScale - scaledThick;
                float phase = pixelX * CURLY_FREQUENCY * 2.0 * M_PI_F / uniforms.cellSize.x;
                float waveY = waveCenter + sin(phase) * CURLY_AMPLITUDE * uniforms.contentScale;
                float dist = abs(pixelY - waveY);
                if (dist < scaledThick * 1.2) {
                    // Smooth anti-aliased edge
                    float alpha = 1.0 - smoothstep(scaledThick * 0.5, scaledThick * 1.2, dist);
                    color.rgb = mix(color.rgb, ulColor, alpha);
                }
            } else if (ulStyle == UL_STYLE_DOTTED) {
                // Dotted underline: alternating dots at bottom
                float dotPeriod = 4.0 * uniforms.contentScale;
                float dotPhase = fmod(pixelX, dotPeriod);
                bool isDot = (dotPhase < dotPeriod * 0.5);
                if (pixelY >= (bottomEdge - scaledThick) && isDot) {
                    color.rgb = ulColor;
                }
            } else if (ulStyle == UL_STYLE_DASHED) {
                // Dashed underline: longer segments at bottom
                float dashPeriod = 8.0 * uniforms.contentScale;
                float dashPhase = fmod(pixelX, dashPeriod);
                bool isDash = (dashPhase < dashPeriod * 0.6);
                if (pixelY >= (bottomEdge - scaledThick) && isDash) {
                    color.rgb = ulColor;
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // B.5.10: Strikethrough rendering — 1px line through glyph center
    // -------------------------------------------------------------------
    if ((attrs & ATTR_STRIKETHROUGH) && !isHidden && !blinkHidden) {
        float pixelY = in.cellUV.y * uniforms.cellSize.y;
        float center = uniforms.cellSize.y * 0.5;
        float scaledStrike = STRIKETHROUGH_THICKNESS * uniforms.contentScale;
        if (pixelY >= (center - scaledStrike * 0.5) &&
            pixelY <  (center + scaledStrike * 0.5)) {
            color.rgb = fg.rgb;
        }
    }

    // -------------------------------------------------------------------
    // B.5.12: Overline rendering — 1px line at top of cell
    // -------------------------------------------------------------------
    if ((attrs & ATTR_OVERLINE) && !isHidden && !blinkHidden) {
        float pixelY = in.cellUV.y * uniforms.cellSize.y;
        float scaledOverline = OVERLINE_THICKNESS * uniforms.contentScale;
        if (pixelY < scaledOverline) {
            color.rgb = fg.rgb;
        }
    }

    // -------------------------------------------------------------------
    // B.5.6: Cursor rendering
    // -------------------------------------------------------------------
    float2 fragPixel = in.cellPixelPos + (in.cellUV * uniforms.cellSize);
    float2 cursorOrigin = float2(
        uniforms.cursorRenderCol * uniforms.cellSize.x,
        uniforms.cursorRenderRow * uniforms.cellSize.y
    );

    // Only render cursor when the application has it visible (DECTCEM mode 25).
    // cursorVisible is the app-level visibility flag; cursorPhase handles blink.
    bool appCursorVisible = (uniforms.cursorVisible > 0.5);

    if (appCursorVisible) {
        float2 cursorMax = cursorOrigin + uniforms.cellSize;
        bool inCursorRect = (
            fragPixel.x >= cursorOrigin.x &&
            fragPixel.x < cursorMax.x &&
            fragPixel.y >= cursorOrigin.y &&
            fragPixel.y < cursorMax.y
        );
        bool cursorVisibleNow = (uniforms.cursorPhase >= 0.5);

        if (inCursorRect) {
            float cursorLocalX = fragPixel.x - cursorOrigin.x;
            float cursorLocalY = fragPixel.y - cursorOrigin.y;

            if (cursorVisibleNow) {
                if (uniforms.cursorStyle == CURSOR_BLOCK) {
                    color.rgb = fg.rgb;
                    if (!isHidden && !blinkHidden) {
                        color.rgb = mix(fg.rgb, bg.rgb, glyphAlpha);
                    }
                } else if (uniforms.cursorStyle == CURSOR_BAR) {
                    if (cursorLocalX < CURSOR_BAR_WIDTH * uniforms.contentScale) {
                        color.rgb = fg.rgb;
                    }
                } else if (uniforms.cursorStyle == CURSOR_UNDERLINE) {
                    if (cursorLocalY >= (uniforms.cellSize.y - CURSOR_UNDERLINE_HEIGHT * uniforms.contentScale)) {
                        color.rgb = fg.rgb;
                    }
                }
            } else if (uniforms.cursorStyle == CURSOR_BLOCK) {
                float borderWidth = uniforms.contentScale;
                bool onBorder = (
                    cursorLocalX < borderWidth ||
                    cursorLocalX > (uniforms.cellSize.x - borderWidth) ||
                    cursorLocalY < borderWidth ||
                    cursorLocalY > (uniforms.cellSize.y - borderWidth)
                );
                if (onBorder) {
                    color.rgb = fg.rgb;
                }
            }
        }

        // -------------------------------------------------------------------
        // B.5.7: Cursor glow effect (Gaussian falloff around cursor cell)
        // -------------------------------------------------------------------
        {
            // Compute distance in cell units from this fragment to cursor center.
            float2 cursorCenter = cursorOrigin + uniforms.cellSize * 0.5;
            float dist = length((fragPixel - cursorCenter) / uniforms.cellSize);

            if (dist > 0.0 && dist < GLOW_RADIUS) {
                // Glow only when cursor is in blink-on phase.
                if (cursorVisibleNow) {
                    float sigma = GLOW_RADIUS / 2.5;
                    float glow = gaussianFalloff(dist, sigma) * GLOW_STRENGTH * uniforms.glowIntensity;
                    // Additively blend a subtle highlight.
                    color.rgb += float3(glow);
                    color.rgb = saturate(color.rgb);
                }
            }
        }
    }

    // -------------------------------------------------------------------
    // B.5.8: Selection overlay rendering
    // -------------------------------------------------------------------
    if (in.flags & FLAG_SELECTED) {
        // Blend a translucent highlight over the cell.
        color.rgb = mix(color.rgb, uniforms.selectionColor.rgb, uniforms.selectionAlpha);
    }

    // Ensure output is fully opaque.
    color.a = 1.0;

    return color;
}

// ---------------------------------------------------------------------------
// MARK: - Gradient Background Utilities
// ---------------------------------------------------------------------------

/// Gradient style constants — must match GradientStyle in GradientBackgroundEffect.swift.
constant uint GRADIENT_LINEAR  = 0;
constant uint GRADIENT_RADIAL  = 1;
constant uint GRADIENT_ANGULAR = 2;
constant uint GRADIENT_DIAMOND = 3;
constant uint GRADIENT_MESH    = 4;

/// Animation mode constants — must match GradientAnimationMode.
constant uint GRAD_ANIM_NONE    = 0;
constant uint GRAD_ANIM_BREATHE = 1;
constant uint GRAD_ANIM_SHIFT   = 2;
constant uint GRAD_ANIM_WAVE    = 3;
constant uint GRAD_ANIM_AURORA  = 4;

/// Hash-based pseudo-random for noise generation (GPU-friendly).
inline float gradientHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Compute animated gradient UV distortion based on animation mode.
inline float2 animateGradientUV(
    float2 uv,
    float time,
    float speed,
    uint mode
) {
    float t = time * speed;

    if (mode == GRAD_ANIM_WAVE) {
        // Undulating wave: offset UV with sine waves.
        float waveX = sin(uv.y * 4.0 + t * 1.5) * 0.03;
        float waveY = cos(uv.x * 3.0 + t * 1.2) * 0.025;
        return uv + float2(waveX, waveY);
    }

    if (mode == GRAD_ANIM_AURORA) {
        // Organic aurora-like flowing distortion.
        float flow1 = sin(uv.x * 2.5 + t * 0.7) * cos(uv.y * 1.8 + t * 0.5);
        float flow2 = cos(uv.x * 1.5 - t * 0.6) * sin(uv.y * 2.2 + t * 0.8);
        return uv + float2(flow1, flow2) * 0.06;
    }

    return uv;
}

/// Convert RGB to HSV for color shifting.
inline float3 rgbToHsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

/// Convert HSV back to RGB.
inline float3 hsvToRgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

/// Compute the gradient color at a UV position with all effects applied.
inline float3 computeGradientColor(
    float2 uv,
    constant TerminalUniforms &uniforms
) {
    // UV (0,0) = top-left, (1,1) = bottom-right — matches screen orientation.
    float2 gradUV = uv;

    float t = uniforms.time * uniforms.gradientAnimationSpeed;

    // Apply UV animation distortion.
    float2 animUV = animateGradientUV(gradUV, uniforms.time, uniforms.gradientAnimationSpeed, uniforms.gradientAnimationMode);

    // Compute blend factor based on gradient style.
    float blend = 0.0;
    float angle = uniforms.gradientAngle;

    if (uniforms.gradientStyle == GRADIENT_LINEAR) {
        // Rotate UV by angle, then use y for blend.
        float cosA = cos(angle);
        float sinA = sin(angle);
        float2 centered = animUV - 0.5;
        float rotated = centered.x * sinA + centered.y * cosA;
        blend = rotated + 0.5;
    } else if (uniforms.gradientStyle == GRADIENT_RADIAL) {
        // Distance from center.
        float2 centered = animUV - 0.5;
        blend = length(centered) * 2.0;
    } else if (uniforms.gradientStyle == GRADIENT_ANGULAR) {
        // Angle from center.
        float2 centered = animUV - 0.5;
        blend = fmod(atan2(centered.y, centered.x) + 2.0 * M_PI_F, 2.0 * M_PI_F) / (2.0 * M_PI_F);
        blend = fract(blend + angle / (2.0 * M_PI_F));
    } else if (uniforms.gradientStyle == GRADIENT_DIAMOND) {
        // Manhattan distance from center.
        float2 centered = abs(animUV - 0.5);
        blend = (centered.x + centered.y);
    } else if (uniforms.gradientStyle == GRADIENT_MESH) {
        // Organic mesh: blend four colors using bilinear-ish UV + noise.
        float2 centered = animUV;
        float noise = sin(centered.x * 3.0 + t * 0.5) * cos(centered.y * 2.5 + t * 0.3) * 0.15;
        centered += noise;
        blend = centered.y; // primary axis
    }

    blend = saturate(blend);

    // Compute base gradient color.
    float3 gradColor;

    if (uniforms.gradientUseMultipleStops > 0.5 && uniforms.gradientStyle == GRADIENT_MESH) {
        // Four-color mesh blend: bilinear interpolation with organic distortion.
        float2 meshUV = animUV;
        float noise1 = sin(meshUV.x * 4.0 + t * 0.4) * 0.08;
        float noise2 = cos(meshUV.y * 3.5 + t * 0.5) * 0.08;
        meshUV += float2(noise1, noise2);
        meshUV = saturate(meshUV);

        float3 top = mix(uniforms.gradientColor1.rgb, uniforms.gradientColor3.rgb, meshUV.x);
        float3 bottom = mix(uniforms.gradientColor2.rgb, uniforms.gradientColor4.rgb, meshUV.x);
        gradColor = mix(top, bottom, meshUV.y);
    } else if (uniforms.gradientUseMultipleStops > 0.5) {
        // Three-stop gradient: color1 → color3 → color2.
        if (blend < 0.5) {
            gradColor = mix(uniforms.gradientColor1.rgb, uniforms.gradientColor3.rgb, blend * 2.0);
        } else {
            gradColor = mix(uniforms.gradientColor3.rgb, uniforms.gradientColor2.rgb, (blend - 0.5) * 2.0);
        }
    } else {
        // Simple two-color gradient.
        gradColor = mix(uniforms.gradientColor1.rgb, uniforms.gradientColor2.rgb, blend);
    }

    // Animation: breathe — pulse intensity.
    if (uniforms.gradientAnimationMode == GRAD_ANIM_BREATHE) {
        float pulse = 1.0 + sin(t * 1.5) * 0.08;
        gradColor *= pulse;
    }

    // Animation: color shift — rotate hue over time.
    if (uniforms.gradientAnimationMode == GRAD_ANIM_SHIFT) {
        float3 hsv = rgbToHsv(gradColor);
        hsv.x = fract(hsv.x + t * 0.03);
        gradColor = hsvToRgb(hsv);
    }

    // Glow effect: radial glow from center.
    if (uniforms.gradientGlowIntensity > 0.001) {
        float2 glowCenter = float2(0.5, 0.5);
        // Animate glow position slightly for organic feel.
        if (uniforms.gradientAnimationMode != GRAD_ANIM_NONE) {
            glowCenter.x += sin(t * 0.3) * 0.05;
            glowCenter.y += cos(t * 0.4) * 0.03;
        }
        float dist = max(distance(uv, glowCenter), 0.001);
        float glowFalloff = exp(-dist * dist / (uniforms.gradientGlowRadius * uniforms.gradientGlowRadius * 0.5));
        float glowPulse = 1.0;
        if (uniforms.gradientAnimationMode != GRAD_ANIM_NONE) {
            glowPulse = 1.0 + sin(t * 2.0) * 0.15;
        }
        gradColor += uniforms.gradientGlowColor.rgb * glowFalloff * uniforms.gradientGlowIntensity * glowPulse;
    }

    // Vignette: subtle edge darkening using smooth distance falloff.
    if (uniforms.gradientVignetteIntensity > 0.001) {
        float2 centered = gradUV - 0.5;
        float dist = length(centered) * 1.414; // normalize: corner dist = 1.0
        // Smooth fade: starts at 40% of viewport, fully dark at edges.
        float vig = 1.0 - smoothstep(0.4, 1.2, dist) * uniforms.gradientVignetteIntensity;
        gradColor *= vig;
    }

    // Film grain / noise.
    if (uniforms.gradientNoiseIntensity > 0.001) {
        float noise = gradientHash(uv * 1000.0 + fract(uniforms.time) * 100.0);
        noise = (noise - 0.5) * uniforms.gradientNoiseIntensity;
        gradColor += noise;
    }

    // Saturation adjustment.
    if (abs(uniforms.gradientSaturation - 1.0) > 0.01) {
        float luminance = dot(gradColor, float3(0.2126, 0.7152, 0.0722));
        gradColor = mix(float3(luminance), gradColor, uniforms.gradientSaturation);
    }

    // Brightness adjustment.
    if (abs(uniforms.gradientBrightness) > 0.001) {
        gradColor += uniforms.gradientBrightness;
    }

    // Contrast adjustment.
    if (abs(uniforms.gradientContrast - 1.0) > 0.01) {
        gradColor = (gradColor - 0.5) * uniforms.gradientContrast + 0.5;
    }

    return saturate(gradColor);
}

// ---------------------------------------------------------------------------
// MARK: - Post-Processing Pass (C.8)
// ---------------------------------------------------------------------------

struct PostVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostVertexOut terminal_post_vertex(uint vid [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    float2 uvs[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };

    PostVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 terminal_post_fragment(
    PostVertexOut in [[stage_in]],
    texture2d<float> sceneTexture [[texture(0)]],
    texture2d<float> previousFrame [[texture(1)]],
    constant TerminalUniforms &uniforms [[buffer(1)]]
) {
    constexpr sampler postSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float2 uv = in.uv;

    // C.2.2: Barrel distortion in post-process.
    if (uniforms.crtEnabled > 0.5 && uniforms.barrelDistortion > 0.0001) {
        float2 ndc = uv * 2.0 - 1.0;
        float r2 = dot(ndc, ndc);
        ndc *= (1.0 + uniforms.barrelDistortion * r2);
        uv = saturate(ndc * 0.5 + 0.5);
    }

    float4 color = sceneTexture.sample(postSampler, uv);

    // Gradient background: paint gradient, then composite terminal on top.
    // The default terminal background is black (0,0,0). We treat near-black
    // pixels as "transparent background" that should be replaced by gradient.
    // Non-black pixels (text, cursor, colored bg) remain visible on top.
    if (uniforms.gradientEnabled > 0.5) {
        float3 grad = computeGradientColor(uv, uniforms);

        // Measure how far this pixel is from pure black.
        float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));

        // Near-black → contentAlpha ≈ 0 (background, show gradient)
        // Bright     → contentAlpha ≈ 1 (text/content, keep terminal color)
        // The smoothstep transition band [0.01, 0.08] gives a soft boundary
        // so anti-aliased glyph edges blend nicely with the gradient.
        float contentAlpha = smoothstep(0.01, 0.08, luminance);

        // Start from gradient, then layer terminal content on top.
        float3 result = grad;
        result = mix(result, color.rgb, contentAlpha);

        // User-adjustable cell transparency: blend a bit of gradient into
        // content pixels too (e.g., for a "frosted glass" effect on text bg).
        if (uniforms.gradientCellBlendOpacity > 0.001 && contentAlpha > 0.01) {
            result = mix(result, grad, uniforms.gradientCellBlendOpacity * contentAlpha);
        }

        color.rgb = result;
    }

    // Knight Rider scanner glow on the username (cursor row, columns 0..usernameLen).
    if (uniforms.scannerEnabled > 0.5 && uniforms.scannerUsernameLen > 0.5) {
        float2 pixel = uv * uniforms.viewportSize;
        float row = floor(pixel.y / uniforms.cellSize.y);
        float col = pixel.x / uniforms.cellSize.x;   // fractional for smooth glow

        float cursorRow = floor(uniforms.cursorRenderRow);
        float nameLen = uniforms.scannerUsernameLen;

        if (row == cursorRow && col < nameLen + 1.0) {
            // Ping-pong sweep: 0 → 1 → 0
            float progress = abs(fract(uniforms.time * uniforms.scannerSpeed * 0.5) * 2.0 - 1.0);
            float scanCol = progress * nameLen;

            // Normalized distance from scanner center.
            float dist = (col - scanCol) / max(nameLen, 1.0);

            // Gaussian glow centered on scan position.
            float width = uniforms.scannerGlowWidth;
            float glow = exp(-dist * dist / (width * width));

            // Asymmetric trailing tail: determine sweep direction from time.
            float sweepPhase = fract(uniforms.time * uniforms.scannerSpeed * 0.5);
            float sweepDir = (sweepPhase < 0.5) ? 1.0 : -1.0; // +1 = moving right, -1 = moving left
            float trailDist = (col - scanCol) * (-sweepDir) / max(nameLen, 1.0);
            float trail = 0.0;
            if (uniforms.scannerTrailLength > 0.001 && trailDist > 0.0) {
                trail = exp(-trailDist / uniforms.scannerTrailLength) * 0.5;
            }

            float scanGlow = saturate(max(glow, trail) * uniforms.scannerIntensity);

            float lum = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
            float textMask = smoothstep(0.01, 0.08, lum);

            // Tint text toward the scanner color (preserving brightness).
            // This works on any text color — rainbow, white, or anything else.
            float3 scannerLit = uniforms.scannerColor.rgb * max(lum * 2.0, 0.15);
            color.rgb = mix(color.rgb, scannerLit, scanGlow * textMask);

            // Subtle background halo behind the scanner even on dark pixels,
            // so the "light" is visible sweeping across the row.
            float bgGlow = glow * 0.12 * uniforms.scannerIntensity;
            color.rgb += uniforms.scannerColor.rgb * bgGlow * (1.0 - textMask);
        }
    }

    // C.2.1: Scanline overlay.
    if (uniforms.crtEnabled > 0.5 && uniforms.scanlineOpacity > 0.001) {
        float2 safeViewport = max(uniforms.viewportSize, float2(1.0, 1.0));
        float pixelY = uv.y * safeViewport.y;
        float scanWave = sin(pixelY * uniforms.scanlineDensity);
        float darken = ((scanWave + 1.0) * 0.5) * uniforms.scanlineOpacity;
        color.rgb *= (1.0 - darken);
    }

    // C.2.3: Phosphor afterglow (previous-frame sampling).
    if (uniforms.crtEnabled > 0.5 && uniforms.phosphorBlend > 0.001) {
        float3 previousRGB = previousFrame.sample(postSampler, uv).rgb;
        color.rgb = max(color.rgb, previousRGB * uniforms.phosphorBlend);
    }

    color.a = 1.0;
    return color;
}
