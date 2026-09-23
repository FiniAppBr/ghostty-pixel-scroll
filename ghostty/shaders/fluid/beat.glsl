// Pass 1 — target: beat buffer, every frame.
//
// Memory. A fragment shader has nowhere to keep anything between frames but
// a buffer, so this one holds two things the rest of the chain cannot work
// out from the current frame alone:
//
//   per texel   r: mean luma of the terminal under this texel last frame
//               g: seconds since that luma last changed
//   global      b: write fatigue (see below)      a: age of the last write
//
// Column 0 is not a texel of the image at all: beat-rows.glsl keeps a
// per-row summary there, so this pass leaves it alone.
//
// The change age is what lets a red spinner be told apart from red error
// text. Both are the same #FF8A8A; the difference is that the spinner's row
// is alive -- its glyph ticks ten times a second and its timer once a second,
// a cell or two at a time -- while an error line, once printed, never changes
// again. So "this row changed a moment ago, and only a little" is the spinner.
//
// --- the fatigue --------------------------------------------------------------
// Each write adds one to a total that decays exponentially, and dye-advect
// turns it into a gain: a keystroke after a pause is worth full strength, one
// in the middle of a burst is worth less, and the burst recovers on its own.
// The write's age is stored rather than its time because these buffers are
// rgba16f and iTime outgrows a half's mantissa within minutes; the age stays
// near zero, where there is room to spare.
const float AGE_CAP = 8.0;
const float RECOVER = 0.35;   // seconds for one write's fatigue to fall to 1/e
const float FAT_CAP = 40.0;
const float DT_MAX  = 1.0 / 30.0;

// A texel's luma is the mean of nine taps spread over it, so a glyph that
// changes anywhere under the texel moves the number.
const float CHANGE_MIN = 0.015;

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// Even frames only, like the rest of the chain: a change in the terminal
// image persists until the next one, so looking every other frame misses
// nothing, and the ages advance by two frames' worth to stay in real time.
const float SIM_STRIDE = 2.0;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 size = vec2(textureSize(iChannel3, 0));
    vec4 prev = texelFetch(iChannel3, ivec2(fragCoord), 0);
    if ((iFrame & 1) != 0) { fragColor = prev; return; }
    if (fragCoord.x < 1.0) { fragColor = prev; return; }   // beat-rows owns it

    float dt  = min(iTimeDelta, DT_MAX) * SIM_STRIDE;
    float age = min(max(iTime - iTimeWriteHead, 0.0), AGE_CAP);
    float wrote = (iWriteHead.z > 0.0 && age < prev.a) ? 1.0 : 0.0;
    float fat = min(prev.b * exp(-dt / RECOVER) + wrote, FAT_CAP);

    // Mean luma under this texel: 3x3 taps a third of a texel apart.
    vec2 texPx = iResolution.xy / size;
    vec2 base  = (fragCoord - 0.5) * texPx;   // this texel's top-left, in px
    float l = 0.0;
    for (int j = 0; j < 3; j++)
        for (int i = 0; i < 3; i++)
            l += luma(texture(iChannel0, (base + (vec2(float(i), float(j)) + 0.5)
                                          * texPx / 3.0) / iResolution.xy).rgb);
    l /= 9.0;

    float changed = abs(l - prev.r) > CHANGE_MIN ? 1.0 : 0.0;
    float tage = changed > 0.0 ? 0.0 : min(prev.g + dt, AGE_CAP);

    fragColor = vec4(l, tage, fat, age);
}
