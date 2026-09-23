// A caret that marks where Claude is writing.
//
// During streamed output the real cursor is hidden and parked in the input
// box, so there is nothing on screen showing where text is arriving. This
// draws a thin bar at the write head — a second caret, only while something
// is actually being written, gone the moment it stops.
//
// The calmest of these: no light over the glyphs, nothing that changes what
// text looks like, just a mark that tells you where to look.

const float WIDTH_PX    = 2.0;   // caret thickness
const float FADE_SECONDS = 0.35; // how long it lingers after writing stops
const float INTENSITY   = 0.85;
const float HEIGHT      = 0.9;   // fraction of the cell height

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    if (INTENSITY <= 0.0) return;

    // Only while a program is writing. Typing moves the real cursor and
    // that already has a caret of its own.
    if (iWriteHead.z <= 0.0 || iTimeWriteHead < iTimeCursorChange) return;

    float cw = max(iWriteHead.z, 1.0);
    float ch = max(iWriteHead.w, 1.0);

    // Just past the character that was written, where the next one goes.
    vec2 c = vec2(iWriteHead.x + cw, iWriteHead.y - ch * 0.5);

    float life = 1.0 - clamp((iTime - iTimeWriteHead) / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return;

    vec2 q = abs(fragCoord - c) - vec2(WIDTH_PX * 0.5, ch * 0.5 * HEIGHT);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    float bar = 1.0 - smoothstep(0.0, 1.2, d);
    if (bar <= 0.0) return;

    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;

    fragColor.rgb = mix(fragColor.rgb, tint, bar * life * INTENSITY);
}
