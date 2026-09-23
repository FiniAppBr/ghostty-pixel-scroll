// Pass 2 of 5 — target: sim buffer.
//
// Advect velocity, add vorticity confinement, inject at the write head, the
// cursor and the mouse. Pressure (b) is carried through untouched; the
// projection passes own that channel.
//
// This is also the one pass that computes the glyph mask, which it leaves in
// alpha for the projection passes to read.

// Velocity decay sets two things at once, and that is what makes it the
// knob for this: steady velocity is force/VEL_DECAY, and the field's memory
// is 1/VEL_DECAY. Multiplying the decay and every CONTINUOUS force below by
// the same factor therefore leaves the standing flow bit-for-bit identical
// while shortening how long the field remembers anything by that factor.
//
// The impulses -- WRITE_FORCE, SMOKE_FORCE, CURSOR_FORCE, FOCUS_PULSE -- are
// deliberately NOT scaled. They land the same kick as before and that kick
// then dies six times faster, so a keystroke gives its sharp initial shove
// and the dye is carried by buoyancy and the draught from then on rather
// than by the wake of the keystroke itself.
//
// At 0.35 the time constant worked out to about thirteen real seconds once
// TIME_SCALE is taken into account, which is why a keystroke was still
// pushing dye around long after it happened. This is nearer two.
//
// The cost is that the memory is shorter for everything transient, not only
// typing: the wake around a glyph, the swirl a scroll leaves, vortices from
// earlier events. The flow is more kinematic and less dynamic than it was.
// --- the timestep -------------------------------------------------------------
// Ghostty stops drawing while the window is occluded, so the frame that comes
// back when you tab in carries the whole gap in iTimeDelta -- tenths of a
// second, sometimes more. Every force here is multiplied by dt and every decay
// is (1 - rate * dt), so one long frame both throws an enormous impulse into
// the field and, past dt = 1/rate, flips the decay negative: velocity reverses
// sign every step and the whole screen shakes.
//
// Clamping is the fix rather than subdividing, because there is nothing to
// catch up on. Nobody watched the seconds that were skipped. The solver just
// carries on from where it was, one ordinary step later.
const float DT_MAX = 1.0 / 30.0;   // seconds of real time one step may carry

const float VEL_DECAY = 2.10;   // 6x
const float VORTICITY = 240.0;  // 6x, with VEL_DECAY

// --- curl noise -------------------------------------------------------------
// A standing field of slow, divergence-free eddies stirred into the velocity.
// Vorticity confinement can only amplify structure the flow already has; this
// creates it, continuously, so the dye has something new to be folded by long
// after the keystroke that launched it.
//
// Divergence-free matters: the projection step exists to remove divergence, so
// a plain noise vector would largely be deleted again a few passes later. This
// takes the curl of a scalar noise field instead, which is divergence-free by
// construction and survives projection intact.
//
// It is close to free. The sim buffer is an eighth scale -- about 77k pixels --
// so even four noise evaluations per pixel is a few million a second, against
// a visible pass that does five million texture fetches per frame.
const float CURL_FORCE = 240.0;  // 6x, with VEL_DECAY
const float CURL_SCALE = 12.0;   // eddies per screen width
const float CURL_DRIFT = 0.10;   // how fast the field itself evolves

// --- the terminal moves the air ---------------------------------------------
// Two ways the fluid answers to what the window is doing. Both only push
// velocity around, so neither can make an edge artifact -- if one is wrong it
// is wrong in magnitude, and magnitude is the constant. Zero either to remove
// that behaviour.

// A scroll drags the air with it. The spring's velocity is in screen pixels
// per second, so it converts the same way the glyph interiors below do.
const float SCROLL_WIND = 0.35;

// Taking focus stirs the air around the cursor: the split you land on comes
// alive at the point you are actually looking at, rather than at the middle
// of a rectangle. Falls back to the centre of the pane when there is no
// cursor to aim at.
//
// Getting this to show up at all took two goes, and the failures are worth
// recording because they are both about what this solver will and will not
// carry.
//
// It began as a shove radially outward, which did nothing whatsoever: a
// radial field is pure divergence, and removing divergence is precisely what
// the eight pressure sweeps downstream are for. The solver deleted it.
//
// Making it a single swirl fixed that -- an azimuthal field has no divergence
// at all -- but it was still invisible, for a different reason: rotating a
// blob that is radially symmetric about the centre it is being rotated
// around changes nothing. The puff is a gaussian sitting exactly on the axis.
//
// So it is a vortex pair. Two counter-rotating vortices side by side drive a
// jet of fluid between them, which is how a real smoke ring moves itself
// along. Divergence-free, because it is built from curls, and asymmetric,
// because the pair has an axis -- so the puff is actually thrown.
const float FOCUS_PULSE  = 1200.0;
const float FOCUS_TAU    = 0.35;    // seconds
const float FOCUS_RADIUS = 0.012;   // size of each vortex
const float FOCUS_SEP    = 0.050;   // half the gap between them
const float WRITE_FORCE = 34.0;
const float CURSOR_FORCE = 9.0;  // per cell of cursor travel
const float SPLAT_RADIUS = 0.0022;
const float TIME_SCALE = 0.22;   // slow motion, applied to the whole solver

// --- half-rate stepping ------------------------------------------------------
// The composite runs at the display's rate because the cursor and the text
// have to. The fluid does not: a solver stepped at 60Hz and a solver stepped
// at 120Hz look the same, because what you see is the dye, and the dye moves
// at the speed of the flow rather than the speed of the clock. So the solver
// steps on even frames with twice the timestep, and on odd frames every pass
// here is a one-tap copy of itself.
//
// The per-frame impulses below are additive rather than rate-based -- they add
// their force once per frame, not once per second -- so they are scaled by the
// stride to keep a keystroke worth the same shove as before.
const float SIM_STRIDE = 2.0;


// A standing draught, and extra lift where there is smoke to lift.
//
// WIND is what the empty field settles to (velocity converges on
// WIND/VEL_DECAY) and WIND_DIR is where it blows: up and to the left, as a
// screen direction. Sim texels are square, so equal components really are
// 45 degrees.
//
// BUOYANCY and the smoke puff push along the same direction rather than
// straight up. They are several times stronger than the draught, so when
// they pulled vertically they simply overruled it and the smoke went up
// with a slight lean; sharing one direction is what actually makes it
// drift.
const float WIND     = 56.0;    // 6x scaling, then eased off
// The lean, shared by the draught AND by buoyancy -- line 229 adds them as
// one vector, (WIND + BUOYANCY * ink). Buoyancy is by far the larger of the
// two wherever there is smoke to lift, so the leftward drift you see in an
// actual plume is set here, not by WIND. Turning WIND down barely touches it.
//
// Was 45 degrees, then 18. Now straight up: no sideways component at all,
// so smoke climbs from where it was born instead of walking across the
// screen. Still normalised, so the rise speed is exactly what it was.
const vec2  WIND_DIR = vec2(0.0, 1.0);   // (-x, +up)
// Lift needs a minimum density before it does anything. Without this the
// ambient haze below would be lifted as hard as anything else, so a layer
// that is meant to hang still would instead climb the screen in a few
// seconds. It only means the thin outer edge of a plume stops lifting before
// its core does, which is what a real one does.
//
// This was BUOYANCY * max(ink - BUOY_MIN, 0.0) -- unbounded, and hinged. Both
// halves of that were a problem, and they only showed up after the ink had had
// time to pile up, which is why it always looked right for the first few
// seconds and then came apart.
//
// Unbounded: ink decays at DYE_DECAY, an eleven-second e-fold, so a spinner
// parked on one row tops it up far faster than it clears. Steady velocity from
// a force is force/VEL_DECAY, so at ink 4 buoyancy was already 171 against a
// wind of 27 and the green's own lift of 36-74. By ink 6 it was 513. Past the
// first couple of units the green stopped being a plume with a lift of its own
// and became a tracer in someone else's updraft.
//
// Hinged: dye-advect's ambient layer settles at AMBIENT_CEIL = 2.5, so the
// whole screen sits just under the old threshold of 3.0, and the typing smoke
// laid over it is mottled by +-60%. That straddles the hinge -- some patches
// cross, the ones beside them do not -- so what reached the flow was close to
// a binary map of updrafts at the mottle's scale, and the green got shredded
// along it. Those are the lumps.
//
// A ramp fixes both at once. It starts above the ambient layer so the haze is
// still left alone, it is wider than the mottle can swing so no patch can be
// lifting while its neighbour is not, and it tops out -- at a force whose
// steady velocity is 86, which is about where this sat during the first few
// seconds, back when it looked right. Ten seconds in now looks like one.
const float BUOY_MIN  = 3.0;    // ink where lift starts
const float BUOY_FULL = 6.0;    // ink where it is lifting as hard as it will
const float BUOY_LIFT = 180.0;  // the force there

// --- the green is hot ---------------------------------------------------------
// The glow is a hot bubble in the grey, and hot air rises through what is
// around it: this is the glow's own buoyancy, read off the dye buffer's green
// channel from the same fetch the ink already costs. While the verb is
// running the bubble sits on it and holds the grey off; when the verb stops
// emitting, the bubble lets go and rises away, and the grey folds in behind
// it. Nothing detects "stopped" -- the behaviour falls out of the buoyancy.
// Steady velocity is force * glow / VEL_DECAY: at a glow of 0.4 this is 38,
// about the green's own lift.
const float GLOW_BUOY = 200.0;
const float GLOW_CAP  = 0.15;   // glow above this lifts no harder: 200*0.15/2.1 = 14 texels/s, well under FIRE_RISE

// Smoke off written output. Both of these are duplicated in dye-advect.glsl,
// which has to reach the same verdict about the same write; keep them in
// step. SMOKE_CHANCE is the "occasionally": a hash of the write time, so a
// fixed fraction of qualifying writes puff and the rest pass quietly.
const float SMOKE_FORCE  = 40.0;
const float SMOKE_CHANCE = 0.22;
const float SAT_MIN      = 0.15;   // below this a glyph counts as plain text
const float SMOKE_RADIUS = 0.0055;

// On Metal the cursor rectangle's y is its bottom edge and +Y runs down the
// screen, so up the screen is -Y. Flip this for a y-up API.
const float UP = -1.0;

// Centre of a cursor-shaped rectangle (x, y, w, h), in uv.
vec2 rectCentre(vec4 r){ return vec2(r.x + r.z * 0.5, r.y - r.w * 0.5) / iResolution.xy; }

// How far a colour is from grey. The terminal's own foreground is nearly
// grey and the background more so, while syntax colour, Claude's bullets and
// its inline code are not, which is the whole trick below.
float sat(vec3 c){ return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }

// 1 when the glyph that just landed should smoke.
//
// Two gates. The first is colour: plain shell output is drawn in the default
// foreground and never qualifies, so this follows Claude's own writing
// rather than everything that scrolls past. A glyph does not fill its cell,
// so three samples across the cell are taken and the most saturated wins.
// The second is a hash of the write time, which is one value per write and
// holds steady for as long as that write is being injected.
float smokeGate() {
    if (iWriteHead.z <= 0.0) return 0.0;
    // The hash gate first: it costs no texture reads and rejects most
    // writes, so the three colour taps below only happen on the small
    // fraction of writes that could still puff.
    float r = fract(sin(iTimeWriteHead * 91.7) * 43758.5453);
    if (r >= SMOKE_CHANCE) return 0.0;
    vec2 c = rectCentre(iWriteHead);
    vec2 step_x = vec2(iWriteHead.z * 0.28, 0.0) / iResolution.xy;
    float m = max(max(sat(texture(iChannel0, c).rgb),
                      sat(texture(iChannel0, c + step_x).rgb)),
                  sat(texture(iChannel0, c - step_x).rgb));
    return smoothstep(SAT_MIN, SAT_MIN + 0.10, m);
}

// Glyph coverage at this point, dilated so a stroke thinner than a sim cell
// still blocks the flow. A block fill is not a glyph -- the air used to
// collide with a whole code block or diff as if it were a wall, and a plume
// crossing one broke on an edge that is not there.
// Kept identical to the copy in dye-advect.glsl on purpose. The two masks have
// to agree about where a letter is, or the ink gets thinned somewhere the
// flow is not being stopped.

// A glyph is something brighter or darker than what is immediately around it.
// A block fill is not: its interior is flat whatever colour it is, and its
// edge against the terminal background is a far smaller step than any letter.
//
// This replaces keying on the colour itself, which cannot be made to work.
// The first attempt asked "is this the background colour", and called every
// code block, diff and prompt band a solid wall. The second added "and bright
// enough", which still let through every fill above the cutoff -- and there is
// no cutoff that separates them, because diffRemoved's luma is 0.173 against a
// background of 0.171 while diffAddedDimmed's is brighter than some text that
// really is text. Absolute brightness does not tell the two apart.
//
// Local contrast does, with room to spare. Every fill Claude paints lands
// within 0.062 luma of whatever it sits on; the dimmest text still legible is
// 0.083 clear of its background and ordinary text is 0.7 clear. The threshold
// sits in a gap an order of magnitude wide.
//
// Luma rather than max(r,g,b), and the channel weights are doing real work:
// those diff fills are coloured, so the max puts #462026 and #1C3A2A well
// clear of the background while luma puts them within a hundredth of it.
//
// Contrast alone is not quite enough, though, because one kind of fill edge
// really is a big step: Claude's word-level diff highlights are bright green
// or red against the row's own darker fill, a jump of 0.27 luma, which is
// squarely in letter territory. No threshold can separate those two, and the
// mask drew a rim around every highlighted word.
//
// What separates them is not how big the step is but its shape. A stroke is an
// extremum -- it has background on BOTH sides, whichever axis it is thin along
// -- while the edge of a filled rectangle is monotone: darker on one side,
// brighter on the other, and it stays that way. So instead of the range across
// the window, take how far the middle of a triple of taps stands clear of both
// its neighbours. A stroke gives its full contrast. A step gives one
// difference of each sign, and comes out at or below zero however large it is.
//
// Both signs count. Text is usually lighter than its ground, but inside those
// same highlights it is darker than it, so a valley has to read as strongly as
// a ridge.
//
// The dilation is why the triples are evaluated at three positions per axis
// rather than one: the test marks the extremum itself and nothing around it,
// so without this a stroke thinner than a sim cell would be missed by most of
// the texels that ought to be blocked by it. Testing at -R, 0 and +R covers
// everything within R of a stroke, which is what the old window did for free.
// It is also why the spacing stays at 2px: at 3 and above each glyph starts
// being echoed at +/-R and the text doubles.
const float MASK_R  = 2.0;    // tap spacing, in source pixels; also the dilation
const float MASK_LO = 0.075;  // below this it is noise, not a letter
const float MASK_HI = 0.170;  // above it, unambiguously a letter

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// How far b stands clear of both a and c: positive for a ridge or a valley,
// zero or less for anything monotone.
float extremum(float a, float b, float c) {
    float d1 = b - a;
    float d2 = b - c;
    return max(min(d1, d2), -max(d1, d2));
}

// Nine taps: the centre, and +/-R and +/-2R along each axis. A cross rather
// than a block, because the corners sit 1.41x further out than the sides and
// barely moved the result.
float solid(vec2 uv) {
    vec2 px = MASK_R / iResolution.xy;
    float c   = luma(texture(iChannel0, uv).rgb);
    float xm2 = luma(texture(iChannel0, uv - vec2(px.x * 2.0, 0.0)).rgb);
    float xm1 = luma(texture(iChannel0, uv - vec2(px.x, 0.0)).rgb);
    float xp1 = luma(texture(iChannel0, uv + vec2(px.x, 0.0)).rgb);
    float xp2 = luma(texture(iChannel0, uv + vec2(px.x * 2.0, 0.0)).rgb);
    float ym2 = luma(texture(iChannel0, uv - vec2(0.0, px.y * 2.0)).rgb);
    float ym1 = luma(texture(iChannel0, uv - vec2(0.0, px.y)).rgb);
    float yp1 = luma(texture(iChannel0, uv + vec2(0.0, px.y)).rgb);
    float yp2 = luma(texture(iChannel0, uv + vec2(0.0, px.y * 2.0)).rgb);

    float e = extremum(xm1, c, xp1);
    e = max(e, extremum(xm2, xm1, c));
    e = max(e, extremum(c, xp1, xp2));
    e = max(e, extremum(ym1, c, yp1));
    e = max(e, extremum(ym2, ym1, c));
    e = max(e, extremum(c, yp1, yp2));
    return smoothstep(MASK_LO, MASK_HI, e);
}

vec2 simTexel(){ return 1.0 / vec2(textureSize(iChannel1, 0)); }

// --- the cell key -------------------------------------------------------------
// How green (or red) the character cell under this texel is. dye-advect used
// to work this out itself, for every dye texel, for every cell whose ball
// could reach it: nine taps a cell, five cells reaching, six hundred thousand
// texels -- some thirty million scattered full-resolution reads a step, and
// all of them asking the same question about the same few hundred cells. A
// sim texel is smaller than a cell, so asking it once per texel HERE answers
// it for every cell on screen in under a million taps, and dye-advect fetches
// the answer. Same nine taps, same keys, same numbers.
//
// Signed: +green, -red. Green keys on colour alone; red only on the spinner
// row, told by the beat buffer's row summary (see beat-rows.glsl): the row
// had a small change (see beat-rows.glsl) within RED_HOLD seconds, and its
// third cell -- where the verb starts -- is red. The spinner
// glyph ticks a cell at a time ten times a second, so its row always
// qualifies; error text never changes, so its row never does; a scroll or a
// new line changes a whole row at once, which is not a small change.
const float KEY_GREEN     = 0.42;
const float KEY_MIN_GREEN = 0.55;
const float KEY_RED       = 0.30;
const float KEY_MIN_RED   = 0.75;
const float RED_HOLD      = 1.30;   // seconds a row stays "alive" after a small change
const vec2  CELL_FALLBACK = vec2(14.0, 34.0);

float greenKey(vec3 c) {
    float lead = c.g - max(c.r, c.b);
    return smoothstep(KEY_GREEN, KEY_GREEN + 0.16, lead)
         * smoothstep(KEY_MIN_GREEN, KEY_MIN_GREEN + 0.2, c.g);
}
float redKey(vec3 c) {
    float lead = c.r - max(c.g, c.b);
    return smoothstep(KEY_RED, KEY_RED + 0.16, lead)
         * smoothstep(KEY_MIN_RED, KEY_MIN_RED + 0.2, c.r);
}

float cellKey(vec2 fragCoord) {
    vec2 cellPx = iWriteHead.zw;
    if (cellPx.x <= 0.0) cellPx = CELL_FALLBACK;
    vec2 cellUV = cellPx / iResolution.xy;
    vec2 px  = fragCoord / vec2(textureSize(iChannel1, 0)) * iResolution.xy;
    vec2 c   = (floor(px / cellPx) + 0.5) * cellUV;

    float g = 0.0, r = 0.0;
    for (int j = -1; j <= 1; j++)
        for (int i = -1; i <= 1; i++) {
            vec3 t = texture(iChannel0,
                    c + vec2(float(i) * 0.25, float(j) * 0.28) * cellUV).rgb;
            g = max(g, greenKey(t));
            r = max(r, redKey(t));
        }
    // The spinner's indicator glyph sits two cells left of the verb and keeps
    // its own colour, which can be the green shimmer while the verb is red.
    // So a green cell in the first two columns takes the verb's colour: if
    // the cell two to its right keys red, it goes red at its own strength.
    if (g > 0.0 && floor(px.x / cellPx.x) < 2.0) {
        vec2 v = c + vec2(2.0 * cellUV.x, 0.0);
        float vr = 0.0;
        for (int j = -1; j <= 1; j++)
            for (int i = -1; i <= 1; i++)
                vr = max(vr, redKey(texture(iChannel0,
                        v + vec2(float(i) * 0.25, float(j) * 0.28) * cellUV).rgb));
        if (vr > 0.0) { r = g; g = 0.0; }
    }
    if (r > 0.0) {
        // beat runs at the same scale as sim, so (0, y) is this row's summary
        vec4 row = texelFetch(iChannel3, ivec2(0, int(fragCoord.y)), 0);
        if (row.r > RED_HOLD || row.b < 0.5) r = 0.0;
    }
    return g >= r ? g : -r;
}

// Alpha carries two things: the glyph mask, binary, as 4 or 0; and the cell
// key above, stored as key + 1.5 so it is never negative. Both decode with
// one comparison and one subtraction; see dye-advect's emitter.
float packA(float solid, float key) {
    return (solid > 0.5 ? 4.0 : 0.0) + (key + 1.5);
}

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i),                  hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// v = (dPsi/dy, -dPsi/dx) for a scalar potential Psi, by finite difference.
// The 1/(2e) of the derivative is folded into CURL_FORCE.
vec2 curlNoise(vec2 p) {
    const float e = 0.35;
    float yp = vnoise(p + vec2(0.0, e));
    float yn = vnoise(p - vec2(0.0, e));
    float xp = vnoise(p + vec2(e, 0.0));
    float xn = vnoise(p - vec2(e, 0.0));
    return vec2(yp - yn, xn - xp);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 ts = simTexel();
    vec2 uv = fragCoord * ts;          // this pass renders at sim resolution

    // Odd frame: nothing steps, so hand back what is already here.
    if ((iFrame & 1) != 0) { fragColor = texture(iChannel1, uv); return; }
    float dt = min(iTimeDelta, DT_MAX) * SIM_STRIDE * TIME_SCALE;

    vec4 s = texture(iChannel1, uv);
    vec2 vel = s.rg;

    // Sim texels per screen pixel: the conversion both the scroll wind and
    // the glyph interiors further down need.
    float simPerPx = float(textureSize(iChannel1, 0).y) / iResolution.y;

    // --- vorticity confinement: put back what the grid keeps eating -------
    float cL = texture(iChannel1, uv - vec2(ts.x, 0.0)).g;
    float cR = texture(iChannel1, uv + vec2(ts.x, 0.0)).g;
    float cB = texture(iChannel1, uv - vec2(0.0, ts.y)).r;
    float cT = texture(iChannel1, uv + vec2(0.0, ts.y)).r;
    float curl = 0.5 * ((cR - cL) - (cT - cB));
    vec2 f = 0.5 * vec2(abs(cT) - abs(cB), abs(cR) - abs(cL));
    f /= length(f) + 1e-4;
    vel += f * VORTICITY * curl * dt;

    // --- semi-Lagrangian advection ---------------------------------------
    vec2 back = uv - dt * vel * ts;
    vel = texture(iChannel1, back).rg * (1.0 - VEL_DECAY * dt);

    // --- wind -------------------------------------------------------------
    // The draught is uniform, so the projection leaves it alone in open
    // space and only fights it at the walls, which is what turns a straight
    // draught into the slow circulation you actually see -- and on a
    // diagonal it has two walls to turn against instead of one.
    vec2 rise = vec2(WIND_DIR.x, UP * WIND_DIR.y);
    vec4  dye  = texture(iChannel2, uv);
    float ink  = dye.r;
    float glow = abs(dye.g);   // signed channel: red is negative
    vel += rise * (WIND + BUOY_LIFT * smoothstep(BUOY_MIN, BUOY_FULL, ink)
                        + GLOW_BUOY * min(glow, GLOW_CAP)) * dt;

    // --- curl noise -------------------------------------------------------
    // Aspect-corrected so the eddies come out round rather than stretched,
    // and drifting so they are a live field rather than fixed stirrers
    // pinned to screen positions.
    vec2 cp = vec2(uv.x * (iResolution.x / iResolution.y), uv.y) * CURL_SCALE
            + vec2(0.0, iTime * CURL_DRIFT);
    vel += curlNoise(cp) * CURL_FORCE * dt;

    // --- the scroll drags the air ------------------------------------------
    vel.y += iScrollVelocity * simPerPx / TIME_SCALE * SCROLL_WIND * dt;

    // --- injection --------------------------------------------------------
    float aspect = iResolution.x / iResolution.y;

    // --- waking up ---------------------------------------------------------
    if (iFocus != 0) {
        float hit = exp(-max(iTime - iTimeFocus, 0.0) / FOCUS_TAU);
        if (hit > 0.01) {
            vec2 c = (iCursorVisible != 0 && iCurrentCursor.z > 0.0)
                   ? rectCentre(iCurrentCursor)
                   : vec2(0.5);
            vec2 p = (uv - c) * vec2(aspect, 1.0);

            // One vortex either side of the cursor, turning opposite ways.
            // Between them the two rotations agree, and that is the jet.
            vec2 q1 = p - vec2(FOCUS_SEP, 0.0);
            vec2 q2 = p + vec2(FOCUS_SEP, 0.0);
            vec2 w = vec2(-q1.y, q1.x) * exp(-dot(q1, q1) / FOCUS_RADIUS)
                   - vec2(-q2.y, q2.x) * exp(-dot(q2, q2) / FOCUS_RADIUS);

            // Normalised by the separation so FOCUS_PULSE stays readable as
            // a speed rather than scaling with the geometry.
            vel += w / (2.0 * FOCUS_SEP) * FOCUS_PULSE * hit * dt;
        }
    }

    // The write head: output landing shoves the fluid. iWriteHead is in
    // pixels with y measured like the cursor rect, so convert the same way
    // cursor-halo.glsl does.
    if (iWriteHead.z > 0.0) {
        float age = max(iTime - iTimeWriteHead, 0.0);
        float hit = exp(-age / 0.12);
        if (hit > 0.01) {
            vec2 p = (uv - rectCentre(iWriteHead)) * vec2(aspect, 1.0);
            vel += exp(-dot(p, p) / SPLAT_RADIUS) * vec2(WRITE_FORCE, WRITE_FORCE * 0.15) * hit * SIM_STRIDE;
        }
    }

    // The cursor: a jump shoves the fluid the way it went, harder for a
    // longer jump, so moving around a file leaves a wake and a single
    // step barely registers on top of what the write head already did.
    if (iCursorVisible != 0 && iCurrentCursor.z > 0.0 && iPreviousCursor.z > 0.0) {
        float age = max(iTime - iTimeCursorChange, 0.0);
        float hit = exp(-age / 0.10);
        vec2 from = rectCentre(iPreviousCursor);
        vec2 to   = rectCentre(iCurrentCursor);
        vec2 jump = (to - from) * iResolution.xy / iCurrentCursor.zw;   // in cells
        float cells = length(jump);
        if (hit > 0.01 && cells > 0.5) {
            vec2 p = (uv - to) * vec2(aspect, 1.0);
            vec2 dir = normalize((to - from) * vec2(aspect, 1.0));
            vel += exp(-dot(p, p) / SPLAT_RADIUS) * dir * CURSOR_FORCE * min(cells, 8.0) * hit * SIM_STRIDE;
        }
    }

    // A puff off Claude's own output. Rises rather than shoves sideways,
    // and over a wider radius than the write splat, so it reads as smoke
    // lifting off the line instead of another nudge along it.
    float puff = smokeGate();
    if (puff > 0.0) {
        float hit = exp(-max(iTime - iTimeWriteHead, 0.0) / 0.22);
        if (hit > 0.01) {
            vec2 p = (uv - rectCentre(iWriteHead)) * vec2(aspect, 1.0);
            vel += exp(-dot(p, p) / SMOKE_RADIUS) * rise * SMOKE_FORCE * puff * hit * SIM_STRIDE;
        }
    }

    // The mouse, so the field can be pushed by hand.
    if (iMouse.z > 0.0) {
        vec2 c = iMouse.xy / iResolution.xy;
        vec2 p = (uv - c) * vec2(aspect, 1.0);
        vec2 d = (iMouse.xy - abs(iMouse.zw)) / iResolution.xy;
        vel += exp(-dot(p, p) / SPLAT_RADIUS) * d * WRITE_FORCE * 12.0 * SIM_STRIDE;
    }

    // Inside a glyph the fluid moves exactly as the glyph does: nothing,
    // unless the grid is sliding under a smooth scroll, in which case the
    // text is a moving wall and carries what is beside it along. The
    // mask is a property of where the text is right now, not of the
    // fluid, so it is sampled fresh here rather than advected.
    //
    // iScrollVelocity is screen px/s; the solver runs in sim texels per
    // slowed second, hence the two conversions.
    float o = solid(uv);
    if (o > 0.5) {
        vel = vec2(0.0, iScrollVelocity * simPerPx / TIME_SCALE);
    }

    fragColor = vec4(clamp(vel, -1000.0, 1000.0), s.b, packA(o, cellKey(fragCoord)));
}
