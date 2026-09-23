// Pass 4 of 5 - target: sim buffer.
//
// Subtract the pressure gradient. What is left is divergence-free, which is
// the property the eye reads as liquid.

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

    float pL = sL.a > 3.5 ? c.b : sL.b;
    float pR = sR.a > 3.5 ? c.b : sR.b;
    float pB = sB.a > 3.5 ? c.b : sB.b;
    float pT = sT.a > 3.5 ? c.b : sT.b;

    vec2 vel = c.rg - vec2(pR - pL, pT - pB) * 0.5;
    if (c.a > 3.5) vel = vec2(0.0);

    fragColor = vec4(vel, c.b, c.a);
}
