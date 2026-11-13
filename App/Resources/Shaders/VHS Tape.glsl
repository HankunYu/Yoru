// VHS tape: colors that bleed sideways, lines that tremble, tape noise, the torn band
// at the foot of the picture where the heads switch, and washed-out contrast.
// Written for Yoru; mpv hook format. The noise moves only while the video plays.

//!HOOK OUTPUT
//!BIND HOOKED
//!DESC VHS tape

#define TAPE_LINES 240.0     // lines down the picture; fewer are coarser
#define COLOR_BLEED 1.0      // sideways smear of the colors, 0 to 3
#define SOFTNESS 1.0         // sideways softness of the picture, 0 to 3
#define JITTER 0.6           // trembling of single lines, 0 to 3
#define WOBBLE 0.5           // slow sideways sway of the whole picture, 0 to 3
#define NOISE 0.5            // grain and color speckle, 0 to 2
#define DROPOUTS 0.5         // white streaks of lost tape signal, 0 to 2
#define HEAD_SWITCH 1.0      // torn band at the bottom edge, 0 to 3
#define FADE 0.5             // washed-out blacks and colors, 0 to 1

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vec3 toYIQ(vec3 c) {
    return vec3(dot(c, vec3(0.299, 0.587, 0.114)),
                dot(c, vec3(0.596, -0.274, -0.322)),
                dot(c, vec3(0.211, -0.523, 0.312)));
}

vec3 toRGB(vec3 c) {
    return vec3(c.x + 0.956 * c.y + 0.621 * c.z,
                c.x - 0.272 * c.y - 0.647 * c.z,
                c.x - 1.106 * c.y + 1.703 * c.z);
}

vec3 sampleYIQ(vec2 uv) {
    return toYIQ(HOOKED_tex(clamp(uv, vec2(0.0), vec2(1.0))).rgb);
}

vec4 hook() {
    float time = float(frame);
    // One tape line, and the width of one tape pixel on the screen.
    float line = floor(HOOKED_pos.y * TAPE_LINES);
    float unit = HOOKED_pt.x * HOOKED_size.y / TAPE_LINES;
    vec2 uv = vec2(HOOKED_pos.x, (line + 0.5) / TAPE_LINES);
    // Halfway between tape lines the picture is a blend of the two.
    uv.y = mix(uv.y, HOOKED_pos.y, 0.5);

    // Lines tremble one by one, and the picture sways as the tape speed drifts.
    float shift = (hash(vec2(line, time)) - 0.5) * JITTER;
    shift += sin(HOOKED_pos.y * 9.0 + time * 0.11) * sin(time * 0.037) * 2.0 * WOBBLE;
    // Now and then a short run of lines slips together.
    float slip = step(0.985, hash(vec2(floor(line / 12.0), floor(time / 5.0))));
    shift += slip * (hash(vec2(line, time + 7.0)) - 0.2) * 6.0 * JITTER;

    // Where the heads switch, at the foot of the picture, lines tear to the side.
    float foot = smoothstep(1.0 - 0.035 * min(HEAD_SWITCH, 1.0), 1.0, HOOKED_pos.y) * step(0.001, HEAD_SWITCH);
    shift += foot * (18.0 + 30.0 * hash(vec2(line, time * 0.5))) * HEAD_SWITCH;
    uv.x += shift * unit;

    // Brightness keeps a few hundred steps along a line; color far fewer, and late.
    float soft = unit * SOFTNESS;
    float y = sampleYIQ(uv).x * 0.4
        + (sampleYIQ(uv - vec2(soft, 0.0)).x + sampleYIQ(uv + vec2(soft, 0.0)).x) * 0.3;
    float bleed = unit * COLOR_BLEED;
    vec2 iq = vec2(0.0);
    iq += sampleYIQ(uv - vec2(bleed * 1.0, 0.0)).yz * 0.30;
    iq += sampleYIQ(uv - vec2(bleed * 3.0, 0.0)).yz * 0.30;
    iq += sampleYIQ(uv - vec2(bleed * 5.5, 0.0)).yz * 0.25;
    iq += sampleYIQ(uv - vec2(bleed * 8.0, 0.0)).yz * 0.15;

    // Tape noise runs along the lines: streaky grain, and speckle in the colors.
    vec2 grain = vec2(floor(HOOKED_pos.x / (unit * 2.0)), line);
    y += (hash(grain + time * 1.7) - 0.5) * 0.10 * NOISE;
    iq += (vec2(hash(grain * 0.5 + time * 2.3), hash(grain * 0.5 - time * 1.3)) - 0.5) * 0.12 * NOISE;
    y += foot * (hash(grain + time) - 0.3) * 0.5;

    // Dropouts: short white streaks where the tape lost its signal.
    float streak = hash(vec2(line * 3.7, floor(time / 2.0)));
    float start = hash(vec2(line, floor(time / 2.0) + 3.0));
    float along = (HOOKED_pos.x - start) / 0.08;
    if (streak > 1.0 - 0.012 * DROPOUTS && along > 0.0 && along < 1.0)
        y = mix(y, 1.0, (1.0 - along) * 0.8);

    // Worn tape: lifted blacks, dulled highlights, thinner color with a warm cast.
    y = mix(y, 0.06 + y * 0.86, FADE);
    iq *= 1.0 - 0.3 * FADE;
    iq.x += 0.012 * FADE;

    return vec4(clamp(toRGB(vec3(y, iq)), 0.0, 1.0), 1.0);
}
