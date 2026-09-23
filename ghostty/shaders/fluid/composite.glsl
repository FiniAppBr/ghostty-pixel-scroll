// The visible pass. A normal `custom-shader` entry, not a buffer pass.
//
// This can sit anywhere in the visible chain. It does not key against the
// terminal image to find the text: dye-advect already did that against the
// pristine image and left the result in the dye buffer's alpha, so whatever
// the shaders ahead of this one have done to the picture does not matter.

const float GAIN = 0.032;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    fragColor = texture(iChannel0, uv);

    vec4 d = texture(iChannel2, uv);
    if (d.a <= 0.0) return;             // a glyph is here; leave it alone

    // Grey smoke. Thin ink is a dim cool grey, thick ink lifts toward
    // white, so density reads as brightness rather than as hue.
    float amt = clamp(d.r * 1.5, 0.0, 4.0);
    vec3 tint = mix(vec3(0.52, 0.55, 0.60), vec3(0.88, 0.90, 0.93),
                    clamp(amt * 0.6, 0.0, 1.0));

    fragColor.rgb += tint * amt * GAIN * d.a;
}
