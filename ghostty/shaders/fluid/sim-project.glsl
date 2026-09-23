// Pass 3 of 5 - target: sim buffer. Run this one many times (~20).
//
// One Jacobi sweep of the pressure solve. Divergence is recomputed from the
// velocity each sweep rather than stored: that costs four taps and saves a
// whole buffer, and the velocity does not change between sweeps anyway.
//
// The glyph mask rides in alpha, put there by sim-advect, so the five taps
// this pass already makes carry the boundary with them. Alpha is packed --
// solid is 4 + cell key, clear is 0 + cell key -- so the test is against 3.5.
//
// --- the ring ---------------------------------------------------------------
// The projection normally solves for the pressure that makes the velocity
// divergence-free. Asking it instead for a divergence of +EXPAND * glow where
// the green is turns the halo into a SOURCE: the solve pushes fluid outward
// from it, smoothly and radially, which is exactly a force ring -- and it is
// the pressure solve drawing it, so it respects the walls and the rest of the
// flow instead of being stamped over them. It runs as long as the verb emits
// and holds the grey off the word; the moment emission stops, the source
// stops with it and the grey folds back in. No event to detect.
//
// One tap of the dye buffer per sweep, at sim resolution: negligible.
const float EXPAND = 40.0;   // outward push per unit of glow

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 ts = 1.0 / vec2(textureSize(iChannel1, 0));
    vec2 uv = fragCoord * ts;

    // Odd frame: nothing steps, so hand back what is already here.
    if ((iFrame & 1) != 0) { fragColor = texture(iChannel1, uv); return; }

    vec4 c  = texture(iChannel1, uv);
    vec4 sL = texture(iChannel1, uv - vec2(ts.x, 0.0));
    vec4 sR = texture(iChannel1, uv + vec2(ts.x, 0.0));
    vec4 sB = texture(iChannel1, uv - vec2(0.0, ts.y));
    vec4 sT = texture(iChannel1, uv + vec2(0.0, ts.y));

    // divergence, with walls and glyphs reflecting
    float vL = (uv.x - ts.x < 0.0 || sL.a > 3.5) ? -c.r : sL.r;
    float vR = (uv.x + ts.x > 1.0 || sR.a > 3.5) ? -c.r : sR.r;
    float vB = (uv.y - ts.y < 0.0 || sB.a > 3.5) ? -c.g : sB.g;
    float vT = (uv.y + ts.y > 1.0 || sT.a > 3.5) ? -c.g : sT.g;
    float div = 0.5 * (vR - vL + vT - vB);
    div -= EXPAND * min(abs(texture(iChannel2, uv).g), 0.15);   // capped: dense glow must not blow itself off the word
    if (c.a > 3.5) div = 0.0;

    // a solid neighbour takes the centre's pressure: dp/dn = 0 at the edge
    float pL = sL.a > 3.5 ? c.b : sL.b;
    float pR = sR.a > 3.5 ? c.b : sR.b;
    float pB = sB.a > 3.5 ? c.b : sB.b;
    float pT = sT.a > 3.5 ? c.b : sT.b;

    fragColor = vec4(c.rg, (pL + pR + pB + pT - div) * 0.25, c.a);
}
