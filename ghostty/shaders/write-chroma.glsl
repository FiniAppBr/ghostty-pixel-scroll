// Colour separation at the write position.
//
// No light is added at all: the red and blue channels are sampled a fraction
// of a pixel apart near where text is arriving, so new characters carry a
// faint colour fringe that settles as they age. On a dark terminal it reads
// as the screen not quite having caught up, which is the joke.
//
// SPLIT_PX is in device pixels, so on a Retina panel it looks half this wide.
// Much above 6 stops being an effect and starts being a legibility problem.

const float SPLIT_PX     = 4.0;  // device pixels; halve this for how it looks on a Retina panel
const float REACH_CELLS  = 6.0;  // how far from the head it reaches
const float FADE_SECONDS = 0.30;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = texture(iChannel0, uv);

    bool writing = iWriteHead.z > 0.0 && iTimeWriteHead >= iTimeCursorChange;
    vec4 rect = writing ? iWriteHead : iCurrentCursor;
    float changed = writing ? iTimeWriteHead : iTimeCursorChange;

    float cw = max(rect.z, 1.0);
    float ch = max(rect.w, 1.0);
    vec2 c = vec2(rect.x + cw * 0.5, rect.y - ch * 0.5);

    float life = 1.0 - clamp((iTime - changed) / FADE_SECONDS, 0.0, 1.0);
    if (life <= 0.0) return;

    // Falls off with distance from the head, measured in cells so it looks
    // the same at any font size.
    vec2 away = (fragCoord - c) / vec2(cw, ch);
    float near = 1.0 - clamp(length(away) / REACH_CELLS, 0.0, 1.0);
    near *= near;
    float amount = near * life * SPLIT_PX;
    if (amount <= 0.01) return;

    vec2 off = vec2(amount, 0.0) / iResolution.xy;
    fragColor.r = texture(iChannel0, uv + off).r;
    fragColor.b = texture(iChannel0, uv - off).b;
}
