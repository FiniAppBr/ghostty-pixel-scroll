// Write-head glow, tuned for streamed output rather than typing.
//
// Ghostty hands a custom shader the cursor rectangle every frame, and while
// a program writes, the cursor sits at the write position. So following the
// cursor follows the output: a soft head that moves along the text as it
// arrives, and fades when writing stops.
//
// Why this is not one of the trail shaders off the shelf. Those are built
// for typing, where the cursor takes short hops along one line, and a long
// streak between two points reads as motion. Streamed output moves the
// cursor differently: it wraps to a new line, it jumps back when a TUI
// repaints, it crosses the whole screen between frames. A smear drawn
// across those jumps is not a trail, it is a strobe. So the tail here is
// drawn only for a short hop on one line, and every other move gets the
// head alone.
//
// Measured against Claude Code before writing: it does not use the
// alternate screen, so the cursor genuinely tracks written text, but it
// does toggle cursor visibility while repainting. Honouring that toggle
// would flicker the glow several times a second, which is why RESPECT_HIDDEN
// is off by default.

// ---- tunables ---------------------------------------------------------

// How long the glow takes to fade once the cursor stops moving. Streaming
// resets this every frame, so it only runs out when writing stops.
const float FADE_SECONDS = 0.22;

// Size of the head, in cursor heights. Below ~0.6 it reads as a hard dot.
const float HEAD_SIZE = 0.95;

// Brightness. 0 is off, and much above 0.8 starts washing out the text.
const float INTENSITY = 0.45;

// The longest same-line move that still gets a tail, in cells. Anything
// further is a wrap or a repaint, and gets the head only.
const float TAIL_MAX_CELLS = 10.0;

// Follow the terminal's own cursor hiding. Off, because a TUI repainting
// itself hides and shows the cursor constantly and the glow would flicker.
// Turn on if you want the glow gone in full-screen programs.
const bool RESPECT_HIDDEN = false;

// ---- shader -----------------------------------------------------------

// Distance from p to the segment ab. The tail is a capsule around this.
float segmentDistance(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);

    if (RESPECT_HIDDEN && iCursorVisible == 0) return;
    if (INTENSITY <= 0.0) return;

    // Follow the write head while a program is writing. Its cursor is
    // hidden and parked in its own input box, so following the cursor
    // alone means following nothing at all during streamed output.
    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);

    // iCurrentCursor.xy is the -X, +Y corner, and Metal's shader space has
    // +Y downward, so the rectangle runs upward from that corner.
    vec2 head = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5);
    // No previous write head exists, so a program writing gets the head
    // alone and only a moving cursor draws a tail.
    vec2 prev = writing ? head : vec2(
        iPreviousCursor.x + max(iPreviousCursor.z, 1.0) * 0.5,
        iPreviousCursor.y - max(iPreviousCursor.w, 1.0) * 0.5);

    // Fade from the last time the cursor moved. While text streams this is
    // reset every frame, so the glow simply rides along.
    float age = max(iTime - changed, 0.0);
    float life = 1.0 - clamp(age / FADE_SECONDS, 0.0, 1.0);
    life *= life;
    if (life <= 0.0) return;

    // A tail only for a short move along one line. A wrap, a scroll or a
    // repaint would otherwise draw a streak across unrelated text.
    vec2 moved = head - prev;
    bool sameLine = abs(moved.y) < ch * 0.5;
    bool shortHop = abs(moved.x) < cw * TAIL_MAX_CELLS;
    vec2 tail = (sameLine && shortHop) ? prev : head;

    float d = segmentDistance(fragCoord, tail, head);
    float radius = ch * HEAD_SIZE;
    float glow = exp(-(d * d) / (radius * radius));

    // The cursor's own colour, so the glow follows the theme. Some themes
    // leave it unset, and a black glow is no glow at all.
    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;

    // Added rather than blended: this should light the text up, not sit on
    // top of it and hide it.
    fragColor.rgb += tint * (glow * life * INTENSITY);
}
