// A soft rule under the line being written, instead of a glow over it.
// The cursor sits on the line receiving output, so underlining that line
// tracks Claude's writing without putting light on top of the glyphs.
const float FADE_SECONDS = 0.5;
const float THICKNESS    = 2.0;   // pixels
const float INTENSITY    = 0.5;
const float FEATHER      = 1.5;   // pixels of softness on the edges

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    if (INTENSITY <= 0.0) return;

    // Follow the write head while a program is writing. Its cursor is
    // hidden and parked in its own input box, so following the cursor
    // alone means following nothing at all during streamed output.
    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float baseY = rect.y + 1.0;      // just under the cell

    float d = abs(fragCoord.y - baseY);
    float band = 1.0 - smoothstep(THICKNESS, THICKNESS + FEATHER, d);
    if (band <= 0.0) return;

    float age = max(iTime - changed, 0.0);
    float life = 1.0 - clamp(age / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return;

    // Brightest at the write position, tapering along the line.
    float reach = iResolution.x * 0.5;
    float along = 1.0 - clamp(abs(fragCoord.x - rect.x) / reach, 0.0, 1.0);

    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;

    fragColor.rgb += tint * (band * life * along * INTENSITY);
}
