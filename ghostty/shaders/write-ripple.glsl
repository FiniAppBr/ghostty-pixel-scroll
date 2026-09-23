// Rings spreading from wherever text is arriving.
//
// The first version of this expanded from the moment the write head last
// moved — which never worked, because during streamed output the head moves
// every frame, so the ring reset before it could grow and never left the
// character. Rings are now on a clock of their own: they pulse outward on a
// fixed period from wherever the head is, so the spread is visible no matter
// how fast text arrives, and they stop when writing does.
//
// The only one of these that distorts the image rather than adding light.
// Keep AMOUNT low — a couple of pixels reads as a shimmer, more reads as a
// fault in the display.

const float PERIOD      = 0.55; // seconds between rings
const float RINGS       = 2.0;  // how many are in flight at once
const float REACH_CELLS = 4.0;  // how far a ring gets before it dies
const float WIDTH_CELLS = 0.5;  // thickness of a ring
const float AMOUNT_PX   = 2.2;  // how far it displaces the text
const float BRIGHT      = 0.22; // light on the ring itself; 0 for pure distortion
const float FADE_SECONDS = 0.5; // how long rings keep coming after writing stops

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = texture(iChannel0, uv);

    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float alive = 1.0 - clamp((iTime - changed) / FADE_SECONDS, 0.0, 1.0);
    if (alive <= 0.0) return;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);
    vec2 c = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5);

    vec2 away = fragCoord - c;
    float d = length(away);
    float reach = REACH_CELLS * cw;
    if (d > reach) return;

    float w = WIDTH_CELLS * cw;
    float total = 0.0;

    // Several rings in flight, each a period further along than the last.
    for (float i = 0.0; i < RINGS; i += 1.0) {
        float phase = fract(iTime / PERIOD - i / RINGS);
        float radius = phase * reach;
        float ring = exp(-pow((d - radius) / w, 2.0));
        // Born bright at the centre, gone by the time it reaches the edge.
        total += ring * (1.0 - phase) * (1.0 - phase);
    }
    total *= alive;
    if (total <= 0.001) return;

    vec2 dir = d > 0.001 ? away / d : vec2(0.0);
    fragColor = texture(iChannel0, uv + dir * (total * AMOUNT_PX) / iResolution.xy);

    if (BRIGHT > 0.0) {
        vec3 tint = iCurrentCursorColor.rgb;
        if (dot(tint, tint) < 0.01) tint = iForegroundColor;
        fragColor.rgb += tint * (total * BRIGHT);
    }
}
