// The classic trail: the cursor's shape stretched between where it was and
// where it is. Tuned for typing; during streamed output it mostly shows the
// short hops, because long jumps are suppressed the same way as elsewhere.
const float FADE_SECONDS   = 0.16;
const float INTENSITY      = 0.55;
const float TAIL_MAX_CELLS = 12.0;

float segDist(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
    if (INTENSITY <= 0.0) return;

    float cw = max(iCurrentCursor.z, 1.0);
    float ch = max(iCurrentCursor.w, 1.0);
    vec2 cur = vec2(iCurrentCursor.x + cw * 0.5, iCurrentCursor.y - ch * 0.5);
    vec2 prv = vec2(iPreviousCursor.x + max(iPreviousCursor.z, 1.0) * 0.5,
                    iPreviousCursor.y - max(iPreviousCursor.w, 1.0) * 0.5);

    vec2 moved = cur - prv;
    if (abs(moved.y) > ch * 0.5 || abs(moved.x) > cw * TAIL_MAX_CELLS) return;
    if (length(moved) < 0.5) return;

    float age = max(iTime - iTimeCursorChange, 0.0);
    float life = 1.0 - clamp(age / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return;

    // A capsule the height of the cursor, spanning the move.
    float d = segDist(fragCoord, prv, cur);
    float body = 1.0 - smoothstep(ch * 0.35, ch * 0.5, d);
    if (body <= 0.0) return;

    vec3 tint = iCurrentCursorColor.rgb;
    if (dot(tint, tint) < 0.01) tint = iForegroundColor;

    fragColor.rgb += tint * (body * life * INTENSITY);
}
