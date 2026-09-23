// A glow that rides the write position.
//
// The obvious way to do this is to follow the cursor, and it does not work.
// Claude Code — and anything else built on a full-screen TUI — draws with the
// cursor hidden and parks it in its own input box, so while text streams in
// the cursor is nowhere near it. That is measured rather than assumed: a
// capture of a real session shows every render wrapped in ESC[?25l ... ESC[?25h
// with the cursor shown only at ESC[2C ESC[3A, its prompt, and the text
// written entirely while it is hidden.
//
// So Ghostty reports the write position separately, as iWriteHead. This
// follows whichever of the two moved last: typing follows the cursor, output
// follows the text, and there is no setting to choose between them.

// ---- tunables ----------------------------------------------------------

const float FADE_SECONDS   = 0.20;  // how long the glow takes to fade out
const float HEAD_SIZE      = 0.85;  // head radius, in cell heights
const float INTENSITY      = 0.40;  // brightness; 0 turns the glow off
const float SMEAR          = 0.0;   // trail brightness; 0 is off
const float SMEAR_SECONDS  = 0.14;  // the trail is shorter-lived than the glow
const float TAIL_MAX_CELLS = 12.0;  // longest hop that still draws a trail

// Alignment escape hatch, in cell heights. Should not be needed: Ghostty
// reports the rectangle as (left, +Y edge, width, height), so the centre is
// y - h/2, and the renderer now folds in the smooth-scroll and cursor-spring
// displacements. -1.0 lifts the effect exactly one cell.
const float Y_NUDGE_CELLS = 0.0;

// Draws a magenta outline around the rectangle Ghostty is reporting, for
// when something looks off. Off in normal use.
const bool DEBUG_RECT = true;

// ---- shader ------------------------------------------------------------

float segDist(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);

    // Whichever moved last is the thing worth following.
    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead > iTimeCursorChange;

    vec4 rect    = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);
    float nudge = Y_NUDGE_CELLS * ch;

    vec2 cur = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5 + nudge);

    // There is no previous write head, so streamed output gets the head
    // alone and only a moving cursor can draw a trail.
    vec2 prv = writing ? cur : vec2(
        iPreviousCursor.x + max(iPreviousCursor.z, 1.0) * 0.5,
        iPreviousCursor.y - max(iPreviousCursor.w, 1.0) * 0.5 + nudge);

    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;

    if (DEBUG_RECT) {
        vec2 q = abs(fragCoord - cur) - vec2(cw, ch) * 0.5;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        if (abs(d) < 1.0) { fragColor.rgb = vec3(1.0, 0.0, 1.0); return; }
    }

    float age = max(iTime - changed, 0.0);

    // A trail only for a short hop along one line. A wrap, a scroll or a TUI
    // repaint moves the cursor somewhere unrelated, and a streak drawn across
    // that is a strobe, not motion.
    vec2 moved = cur - prv;
    bool trail = abs(moved.y) < ch * 0.5 &&
                 abs(moved.x) < cw * TAIL_MAX_CELLS &&
                 length(moved) > 0.5;

    if (INTENSITY > 0.0) {
        float life = 1.0 - clamp(age / FADE_SECONDS, 0.0, 1.0);
        life *= life;
        if (life > 0.0) {
            float d = segDist(fragCoord, trail ? prv : cur, cur);
            float r = ch * HEAD_SIZE;
            fragColor.rgb += tint * (exp(-(d * d) / (r * r)) * life * INTENSITY);
        }
    }

    if (SMEAR > 0.0 && trail) {
        float life = 1.0 - clamp(age / SMEAR_SECONDS, 0.0, 1.0);
        if (life > 0.0) {
            float d = segDist(fragCoord, prv, cur);
            float body = 1.0 - smoothstep(ch * 0.35, ch * 0.5, d);
            fragColor.rgb += tint * (body * life * SMEAR);
        }
    }
}
