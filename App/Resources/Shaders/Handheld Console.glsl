// Handheld console: the picture as a small four-shade liquid crystal screen shows it,
// in large square pixels with a visible grid. Written for Yoru; mpv hook format.

//!HOOK OUTPUT
//!BIND HOOKED
//!DESC Handheld console

#define ROWS 144.0           // pixels down the picture; fewer are larger
#define SHADES 4.0           // steps from dark to light, 2 to 8
#define DITHER 1.0           // dot pattern between shades, 0 to 1
#define CONTRAST 1.2         // spread of the picture before it is reduced, 0.5 to 2
#define GRID 0.35            // darkness of the lines between pixels, 0 to 1
#define COLOR 0.0            // 0 green screen; 1 keeps the picture's own colors

// Darkest and lightest of the green screen.
const vec3 dark = vec3(0.06, 0.22, 0.06);
const vec3 light = vec3(0.61, 0.74, 0.06);

// Ordered dither thresholds, 4 by 4.
float threshold(vec2 cell) {
    vec2 p = mod(cell, 4.0);
    float index = p.x + p.y * 4.0;
    float value = 0.0;
    if (index < 0.5) value = 0.0;
    else if (index < 1.5) value = 8.0;
    else if (index < 2.5) value = 2.0;
    else if (index < 3.5) value = 10.0;
    else if (index < 4.5) value = 12.0;
    else if (index < 5.5) value = 4.0;
    else if (index < 6.5) value = 14.0;
    else if (index < 7.5) value = 6.0;
    else if (index < 8.5) value = 3.0;
    else if (index < 9.5) value = 11.0;
    else if (index < 10.5) value = 1.0;
    else if (index < 11.5) value = 9.0;
    else if (index < 12.5) value = 15.0;
    else if (index < 13.5) value = 7.0;
    else if (index < 14.5) value = 13.0;
    else value = 5.0;
    return (value + 0.5) / 16.0 - 0.5;
}

// Reduces a value to the screen's few steps, with dots standing in for those between.
vec3 reduce(vec3 value, vec2 cell) {
    float steps = max(1.0, SHADES - 1.0);
    return clamp(floor(value * steps + 0.5 + threshold(cell) * DITHER) / steps, 0.0, 1.0);
}

vec4 hook() {
    // Square pixels, sized by how many go down the picture.
    float size = HOOKED_size.y / ROWS;
    vec2 position = HOOKED_pos * HOOKED_size / size;
    vec2 cell = floor(position);
    vec2 center = (cell + 0.5) * size * HOOKED_pt;

    // A pixel shows the average of what it covers.
    vec2 quarter = 0.25 * size * HOOKED_pt;
    vec3 color = HOOKED_tex(center + quarter * vec2(-1.0, -1.0)).rgb
        + HOOKED_tex(center + quarter * vec2(1.0, -1.0)).rgb
        + HOOKED_tex(center + quarter * vec2(-1.0, 1.0)).rgb
        + HOOKED_tex(center + quarter * vec2(1.0, 1.0)).rgb;
    color = clamp((color * 0.25 - 0.5) * CONTRAST + 0.5, 0.0, 1.0);

    float level = dot(color, vec3(0.299, 0.587, 0.114));
    vec3 green = mix(dark, light, reduce(vec3(level), cell).x);
    vec3 result = mix(green, reduce(color, cell), clamp(COLOR, 0.0, 1.0));

    // The gap between one pixel and the next.
    vec2 inside = abs(fract(position) - 0.5) * 2.0;
    float gap = smoothstep(0.78, 1.0, max(inside.x, inside.y));
    result *= 1.0 - GRID * gap;

    return vec4(result, 1.0);
}
