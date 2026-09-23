// A thin ring around the cursor rather than a filled glow. Nothing is laid
// over the glyphs, so text stays exactly as legible as it was.
const float FADE_SECONDS = 0.28;
const float RING_WIDTH   = 1.6;   // pixels
const float RING_GROW    = 6.0;   // pixels it expands while fading
const float INTENSITY    = 0.7;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    if (INTENSITY <= 0.0) return;

    // Follow the write head while a program is writing. Its cursor is
    // hidden and parked in its own input box, so following the cursor
    // alone means following nothing at all during streamed output.
    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);
    vec2 c = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5);

    float age = max(iTime - changed, 0.0);
    float life = 1.0 - clamp(age / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return;

    // Distance to the cursor rectangle's edge.
    vec2 halfSize = vec2(cw, ch) * 0.5 + (1.0 - life) * RING_GROW;
    vec2 q = abs(fragCoord - c) - halfSize;
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);

    float ring = 1.0 - smoothstep(0.0, RING_WIDTH, abs(dist));
    if (ring <= 0.0) return;

    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;

    fragColor.rgb += tint * (ring * life * INTENSITY);
}
