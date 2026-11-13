// CRT television: thick scanlines, phosphor stripes, a curved tube, darkened corners
// and a faint flicker. Written for Yoru; mpv hook format.
//
// The scanlines are sized in screen pixels, not counted down the picture, so they stay
// as visible on a dense phone screen as on a large one.

//!HOOK OUTPUT
//!BIND HOOKED
//!DESC CRT television

#define LINE_HEIGHT 9.0      // thickness of one scanline, in screen pixels
#define SCANLINE_DEPTH 0.85  // how dark the gaps between lines get, 0 to 1
#define BEAM_WIDTH 0.55      // how much of a line the beam fills, 0.2 thin to 1 no gaps
#define MASK_DEPTH 0.25      // strength of the red, green and blue stripes, 0 to 1
#define BLUR 0.5             // horizontal softness, in scanline heights
#define CURVATURE 0.08       // bulge of the tube; 0 is flat
#define VIGNETTE 0.35        // darkening toward the corners, 0 to 1
#define FLICKER 0.04         // brightness shimmer and the slow rolling band, 0 to 0.2

// Bends the picture as a bulging tube would show it.
vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    uv += uv * (uv.yx * uv.yx) * CURVATURE;
    return uv * 0.5 + 0.5;
}

// The picture as the beam draws it: smeared along the line.
vec3 beam(vec2 uv) {
    float reach = HOOKED_pt.x * LINE_HEIGHT * BLUR;
    vec3 color = HOOKED_tex(uv).rgb * 0.34;
    color += (HOOKED_tex(uv - vec2(reach * 0.5, 0.0)).rgb + HOOKED_tex(uv + vec2(reach * 0.5, 0.0)).rgb) * 0.22;
    color += (HOOKED_tex(uv - vec2(reach, 0.0)).rgb + HOOKED_tex(uv + vec2(reach, 0.0)).rgb) * 0.11;
    return color;
}

vec4 hook() {
    vec2 uv = curve(HOOKED_pos);
    // Past the edge of the tube.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return vec4(0.0, 0.0, 0.0, 1.0);

    // Each scanline draws one row of the picture: detail between rows is lost.
    float lines = max(1.0, floor(HOOKED_size.y / LINE_HEIGHT));
    float line = uv.y * lines;
    vec3 color = beam(vec2(uv.x, (floor(line) + 0.5) / lines));

    // Bright along the middle of a line and falling off to the gap. A bright picture
    // spreads the beam, so highlights fill their gaps and shadows show them most.
    float level = dot(color, vec3(0.299, 0.587, 0.114));
    float away = abs(fract(line) - 0.5) * 2.0;
    float width = BEAM_WIDTH * (0.75 + 0.6 * level);
    float lit = exp(-(away * away) / (width * width));
    color *= mix(1.0, lit, SCANLINE_DEPTH);

    // Red, green and blue phosphor stripes, three to a scanline height.
    float stripe = max(1.0, floor(LINE_HEIGHT / 3.0));
    float phase = mod(floor(uv.x * HOOKED_size.x / stripe), 3.0);
    vec3 mask = vec3(1.0 - MASK_DEPTH);
    if (phase < 0.5) mask.r = 1.0;
    else if (phase < 1.5) mask.g = 1.0;
    else mask.b = 1.0;
    color *= mask;

    // Make up for the light the gaps and the mask take away.
    color *= 1.0 + 0.9 * SCANLINE_DEPTH * (1.0 - 0.6 * BEAM_WIDTH) + 0.7 * MASK_DEPTH;

    // The whole picture shimmers, and a faint brighter band rolls down it.
    float time = float(frame);
    float band = smoothstep(0.85, 1.0, fract(uv.y * 0.8 - time * 0.004));
    color *= 1.0 + FLICKER * (0.5 * sin(time * 2.1) + 1.5 * band);

    vec2 edge = uv * (1.0 - uv);
    color *= mix(1.0, pow(clamp(edge.x * edge.y * 16.0, 0.0, 1.0), 0.4), VIGNETTE);
    // Soft rim where the tube meets its frame.
    color *= smoothstep(0.0, 0.006, edge.x) * smoothstep(0.0, 0.006, edge.y);

    return vec4(color, 1.0);
}
