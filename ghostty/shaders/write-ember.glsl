// Text cools as it is written.
//
// Not a glow on a point: the characters themselves stay warm for a moment
// after they arrive and settle back to their normal colour behind the write
// head. Only glyphs light up — the gaps between them stay dark — because the
// warmth is scaled by what is actually drawn in each pixel.
//
// This is the one that needs iWriteHead. During streamed output Ghostty's
// cursor is hidden and parked in the program's input box; the write head is
// the only thing that follows the text.

const float TRAIL_CELLS = 14.0;  // how far back the warmth reaches
const float FADE_SECONDS = 0.45; // how long it lingers once writing stops
const float INTENSITY   = 0.55;  // 0 turns it off
const vec3  WARM = vec3(1.0, 0.62, 0.25);

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    if (INTENSITY <= 0.0) return;

    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);
    vec2 head = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5);

    float life = 1.0 - clamp((iTime - changed) / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return;

    // Only the row being written, and only what is behind the head: text
    // ahead of it has not been written yet.
    if (abs(fragCoord.y - head.y) > ch * 0.5) return;
    float behind = (head.x - fragCoord.x) / cw;
    if (behind < -0.5) return;

    float heat = exp(-max(behind, 0.0) / TRAIL_CELLS);

    // Scaled by how much ink is in this pixel, so the warmth rides the
    // letters rather than washing the line.
    float ink = dot(fragColor.rgb - iBackgroundColor, vec3(0.299, 0.587, 0.114));
    ink = clamp(ink * 2.0, 0.0, 1.0);

    fragColor.rgb += WARM * (heat * life * ink * INTENSITY);
}
