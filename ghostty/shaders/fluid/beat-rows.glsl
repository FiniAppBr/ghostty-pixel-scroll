// Pass 2 — target: beat buffer, every frame. Runs right after beat.glsl.
//
// The per-row summary, kept in column 0: for the terminal row this texel's
// centre lies in,
//   r: seconds since the row last changed by a LITTLE -- at most SMALL
//      texels. A big change (a new line shifting everything, a scroll, a
//      verb being replaced) is ignored rather than counted against the
//      row, because while Claude streams or thinks the whole region is
//      repainted many times a second, and "the latest change was small"
//      was false nearly always. The spinner's glyph ticks a cell at a
//      time between those repaints, and that is what this remembers.
//   g: how many texels changed in the latest change, for the debug view
//   b: whether the row's third cell is red -- where a spinner's verb starts.
//      A red bullet on a tool line pulses while the tool runs, so "alive"
//      alone is not enough; the verb's column is what a bullet line lacks.
// Every column-0 texel in the same row band computes the same summary, so
// a reader can fetch (0, its own y) without knowing where the band starts.
// Everything else is a copy. Two hundred texels scanning fourteen hundred
// each is nothing.
const vec2  CELL_FALLBACK = vec2(14.0, 34.0);
const float AGE_CAP = 8.0;
const float DT_MAX  = 1.0 / 30.0;
const float SMALL   = 40.0;   // sim texels: the glyph tick plus a timer digit or two
const float KEY_RED     = 0.30;   // as in sim-advect.glsl
const float KEY_MIN_RED = 0.75;
float redKey(vec3 c) {
    float lead = c.r - max(c.g, c.b);
    return smoothstep(KEY_RED, KEY_RED + 0.16, lead)
         * smoothstep(KEY_MIN_RED, KEY_MIN_RED + 0.2, c.r);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    ivec2 size = textureSize(iChannel3, 0);
    ivec2 me   = ivec2(fragCoord);
    vec4  here = texelFetch(iChannel3, me, 0);
    if ((iFrame & 1) != 0) { fragColor = here; return; }   // even frames, as beat.glsl
    if (me.x != 0) { fragColor = here; return; }

    vec2  cellPx = iWriteHead.z > 0.0 ? iWriteHead.zw : CELL_FALLBACK;
    float cellH = cellPx.y;
    float texH  = iResolution.y / float(size.y);
    float band  = floor(fragCoord.y * texH / cellH);
    int y0 = max(int(floor( band        * cellH / texH - 0.5)), 0);
    int y1 = min(int(ceil ((band + 1.0) * cellH / texH + 0.5)), size.y - 1);

    float n = 0.0;
    for (int y = y0; y <= y1; y++) {
        if (floor((float(y) + 0.5) * texH / cellH) != band) continue;
        for (int x = 1; x < size.x; x++)
            if (texelFetch(iChannel3, ivec2(x, y), 0).g <= 0.0) n += 1.0;
    }

    float dt = min(iTimeDelta, DT_MAX) * 2.0;   // two frames per step
    float rowAge = (n > 0.0 && n <= SMALL) ? 0.0 : min(here.r + dt, AGE_CAP);
    float count  = n > 0.0 ? n : here.g;
    // The third cell of this row: nine taps, the same grid sim-advect keys on.
    vec2 cellUV = cellPx / iResolution.xy;
    vec2 v = vec2(2.5 * cellUV.x, (band + 0.5) * cellUV.y);
    float verbRed = 0.0;
    for (int j = -1; j <= 1; j++)
        for (int i = -1; i <= 1; i++)
            verbRed = max(verbRed, redKey(texture(iChannel0,
                    v + vec2(float(i) * 0.25, float(j) * 0.28) * cellUV).rgb));
    fragColor = vec4(rowAge, count, verbRed, 0.0);
}
