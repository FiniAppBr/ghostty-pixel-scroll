// Pass 5 of 5 — target: dye buffer.
//
// Carry the ink along the velocity field and release more at the write head.
// Runs at its own, finer scale: the dye is what you see, the velocity is only
// what moves it, so they do not need the same resolution.

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

const float DYE_DECAY = 0.20;    // low: trails linger

// --- sharpening the advection -----------------------------------------------
// Plain semi-Lagrangian advection samples the dye at the back-traced point
// with bilinear filtering, and bilinear filtering is a blur. Applied sixty
// times a second it convolves the whole field with a tent kernel over and
// over, so anything near texel scale is averaged away within a few steps and
// only the large rolls survive. That is what makes fluid smoke look like milk:
// the structure is being created and then immediately destroyed.
//
// MacCormack corrects for it. Advect forward, advect that result back again,
// and the difference between where the round trip lands and where it started
// is the error the two interpolations introduced. Adding back half of it
// cancels most of the first-order diffusion, which is what lets filaments
// survive long enough to be seen.
//
// The correction can overshoot into new extrema and ring, so it is limited to
// the range of the two samples it was built from. That is a cruder limiter
// than clamping to the full back-traced neighbourhood, but that would cost
// four more taps and this one costs none.
//
// The correction is damped against the glyph mask. The dye is cut to zero
// inside every letter, so a line of text is a row of sharp holes in the
// field -- and sharpening a discontinuity is how you get ringing. Left
// undamped it draws bands along every text row. Away from the letters there
// is nothing to ring against and the correction runs at full strength.
const float MACCORMACK = 0.35;   // 0 = plain advection, 1 = full correction

// --- the glow ---------------------------------------------------------------
// Any green pixel emits. Not the crest, not a shape anyone has to find: the
// rule is simply that greenness is a source, so a fully green word emits
// along its whole length and a half-shimmered one emits only where the wave
// has reached. This replaces a dedicated 48-tap blur -- the solver already
// spreads what it carries, and spreading is what a blur is.
//
// It decays far faster than the smoke does, which is what keeps it a halo
// hugging the letters instead of a green trail blowing away up-left. Raise
// GLOW_DECAY to tighten it, lower it to let it stream.
// Fire, not smoke -- and the fire is one constant lift. That is a deliberate
// simplification arrived at the hard way. The lift used to be a function of
// the glow's age (rise, peak, fall), and age is a field, so the lift varied
// from texel to texel. Three separate failures came out of that one property,
// and each got its own patch before the pattern was seen:
//
//   - its gradient made gvel divergent, and semi-Lagrangian advection in a
//     divergent field squeezes the density into lumps (a volume correction,
//     four taps and a clamp were added to undo it);
//   - it was flat inside the emitter and stepped to nothing one texel past
//     it, so neighbouring texels back-traced to points four pixels apart and
//     the glow tore along a hard line (a floor under the age reset was added);
//   - it was evaluated from the DESTINATION texel's own age, so a texel that
//     had never held glow -- every texel inside a letter -- sat at AGE_MAX
//     with no lift at all and could never pull glow in. Inside a glyph vel is
//     zero, so lift was the only way in, and the "porous" letters were walls
//     after all: the plume rose to the underside of the row above and stopped
//     flat. Measured directly: glow 0 above the row, |vy| 45 into it.
//
// A constant has none of those: zero divergence, nothing to step across, and
// the same pull at every texel including the ones inside a letter. GLOW_DECAY
// gives a parcel a visible life of a fraction of a second, so the rise-and-
// fall was never actually seen -- what read as young-spreads/old-rises was
// the emitter's footprint plus a plume, and both are still here. Age stays in
// the buffer for the composite's fade only.
const float FIRE_RISE   = 40.0;  // the lift, in sim texels per slowed second
const float GLOW_DECAY  = 6.0;   // was 12; a tendril needs the length, and the crest's trail has to last the sweep
// A ball is several times the area of the strokes it replaces, so this is
// per-texel rate, not total light. Raised from 4 when the lift became a
// constant: newborn glow used to pool on the word under near-zero lift before
// rising, and now it leaves at once, which halved the peak (measured R 142 ->
// 77 through the debug render). This is the knob for that; FIRE_RISE is not.
const float GLOW_AMT    = 10.1;  // 7 * 1.2 * 1.2
const float AGE_MAX     = 4.0;   // clamp, so the channel cannot run away

// --- the edges ---------------------------------------------------------------
// The pane's border breathes: the cells just outside the framebuffer count as
// emitters too, so a white haze seeps in from every edge and rises through
// the same transport the green uses. This began as an accident -- the cell
// keys moved into the sim buffer, a fetch outside it came back zero, and zero
// decoded as a fully red cell -- and it looked good enough to keep. It is
// white now, and half as strong.
//
// A third colour needs a third state, and the glow channel's sign has only
// two. So whiteness is a FRACTION, 0..1, carried in the dye buffer's alpha
// (nothing downstream read the mask that used to sit there), advected with
// the glow and pulled towards 1 by white birth and 0 by coloured birth, the
// same way the age is pulled towards zero. A fraction blends: where green
// and white meet the sampler gives a greenish white, not a seam.
const float EDGE_KEY    = 0.0;    // off. 0.75 was the white haze seeping in from the pane edges

// +Y is down on Metal, so up the screen is -Y. Straight up: the smoke leans
// up-left with the wind, the fire does not.
const vec2  FIRE_DIR    = vec2(0.0, -1.0);

// --- the wisps ---------------------------------------------------------------
// Incense, not a candle: the green rises in thin tendrils that meander, and
// the meander is a swirl added to its own velocity. It is a CURL -- the
// rotated gradient of a scalar noise -- which is divergence-free by
// construction, so it can be added to gvel without bringing back any of the
// compression the constant lift was chosen to avoid. Nothing else may be
// added to gvel that is not.
//
// The noise is stretched taller than it is wide, so the eddies it makes are
// tall and narrow and the tendrils come out vertical and thin rather than as
// round curls, and it drifts up the screen with the smoke so a wisp keeps its
// shape as it climbs instead of writhing in place. Two octaves, the second
// drifting at a different rate, is what makes the writhing.
const float WISP_SCALE  = 34.0;   // eddies per screen height
const float WISP_TALL   = 0.45;   // vertical stretch: lower = taller tendrils
const float WISP_FORCE  = 32.0;   // swirl speed, sim texels per slowed second
const float WISP_DRIFT  = 0.55;   // how fast the pattern climbs
// The green's own sharpening. The shared MACCORMACK is set for the smoke,
// where ringing against the glyph holes is the constraint; the green has no
// holes now and wants its filaments kept, so it corrects harder.
const float GLOW_SHARPEN = 0.65;


// --- the global taper --------------------------------------------------------
// What a write is worth right now. beat.glsl counts write events and fades
// the count, so this is 1.0 after a pause and falls off the faster the
// terminal is being written to; see the note there for why the local
// `appetite` below is not enough on its own.
//
// The two compose rather than overlap: appetite asks what the air at this
// texel will still take, this asks how hard the whole terminal is being
// written to.
//
// A zero reads as "no beat buffer declared" -- an undeclared channel binds to
// a 1x1 black texture, and this shader should not go silent because the
// config and the chain drifted apart. The real value can never be zero; it
// bottoms out at beat.glsl's FLOOR.
const float BEAT_SAT   = 5.0;    // standing fatigue that costs a factor of 1/e
const float BEAT_FLOOR = 0.30;   // the least a write is ever worth
float writeGain() {
    float fat = texture(iChannel3, vec2(0.5)).b;   // any texel off column 0
    return BEAT_FLOOR + (1.0 - BEAT_FLOOR) * exp(-fat / BEAT_SAT);
}

// --- the emitter -------------------------------------------------------------
// A ball per cell, not the letterform. Green used to emit from the pixel it
// sat on, so the source was the strokes themselves and the glow came out as an
// outline of the word rather than something the word sits in.
//
// The balls are placed on the CELL grid, which is the one thing that makes
// this safe. Dilating the ink instead -- sampling a ring around every texel --
// puts a fixed pattern of probes against text that is itself on a regular
// pitch, and the two beat against each other: whether a probe finds a stroke
// repeats along the line, and that comes out as vertical stripes standing in
// the smoke. Snapping to the same grid the characters are on turns that
// resonance into alignment.
// In cell WIDTHS, because the search below is counted in cells across. They
// came out square before because the radius outgrew that search: the falloff
// was round, but only the cell a texel sat in and its two neighbours were ever
// asked, so everything past them was cut off flat and the blob was clipped to
// a box one row tall and three cells wide.
// Wider than it is tall, on purpose. The verb's base colour is a grey that
// carries nothing to key on, so only the shimmer crest emits -- two or three
// letters at a time -- and a round ball drew that as a small blob wandering
// along the word. Stretching the reach along the row lights about seven cells
// from one crest, and with the crest sweeping and the glow lingering a little
// (GLOW_DECAY), the whole word reads as lit rather than the crest alone.
const float BALL_RX   = 3.00;   // reach along the row, in cell widths
const float BALL_RY   = 2.00;   // reach up and down, in cell widths
const float BALL_CORE = 0.35;   // how much of it is flat before the falloff
const vec2  CELL_FALLBACK = vec2(14.0, 34.0);  // px, if no write head exists

// The keys themselves -- KEY_GREEN and friends -- live in sim-advect.glsl
// now, which works each cell out once and leaves the answer in the sim
// buffer's alpha for the emitter below to fetch.
//
// The glow channel is signed: green glyphs put positive glow in, red ones
// negative. Everything downstream -- transport, sharpening, decay, buoyancy,
// the ring -- works on the magnitude, so a red word gets exactly the smoke a
// green one does, and only the composite looks at the sign to pick the
// colour. Red is the spinner only; sim-advect says how it knows.
const float DYE_AMT   = 0.32;    // ink is a scalar; composite colours it
const float SPLAT_RADIUS = 0.0022;
const float TIME_SCALE = 0.22;

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


// The ink half of the smoke puff. These three must match sim-advect.glsl,
// which decides the same thing about the same write; see the note there.
// How much more smoke the air here will still accept. Typing used to add at
// a flat rate per keystroke, so a long burst piled density onto ground that
// was already thick and the plume went from interesting to a wall.
//
// Injection is scaled by exp(-density/WRITE_SAT): full where the air is
// clear, tapering smoothly as it fills, so density approaches a ceiling
// instead of climbing without bound. The first keystrokes read exactly as
// strongly as they always did -- nothing is taken away from them -- and only
// sustained typing is held back.
//
// Deliberately an exponential rather than a clamp. A hard cap would let the
// plume climb at full rate and then stop dead, and that boundary shows up as
// a flat top on the densest part, which is the same failure the composite's
// clamps used to have.
const float WRITE_SAT    = 9.0;

const float SMOKE_AMT    = 0.46;
const float SMOKE_CHANCE = 0.22;
const float SAT_MIN      = 0.15;
const float SMOKE_RADIUS = 0.0055;

// --- taking focus -----------------------------------------------------------
// A burst of smoke at the cursor when the split is selected, so the swirl
// sim-advect.glsl puts there has something of its own to throw around rather
// than only stirring whatever happened to be lying about. Wider and shorter
// than a keystroke's puff: it should read as one event, not as typing.
//
// Born blotchy like the other puffs, so the solver has something to pull into
// filaments as it scatters.
const float FOCUS_PUFF        = 0.22;
const float FOCUS_PUFF_RADIUS = 0.0080;
const float FOCUS_PUFF_TAU    = 0.25;   // seconds

float sat(vec3 c){ return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }

// --- texture ----------------------------------------------------------------
// Real smoke is not textured by a post-process; it is textured because it was
// never uniform to begin with. So the puff is born blotchy rather than as a
// smooth gaussian, and the solver does the rest -- over the next second it
// stretches those blotches into filaments along the flow, which is structure
// no amount of noise laid over the top could imitate.
//
// It costs nothing anywhere else: this only runs on the pixels of a frame
// that is actually emitting, which is a small radius on a small fraction of
// frames, and it is arithmetic rather than another texture fetch.
//
// The scale is deliberately coarse -- a few blobs across the puff, not grain.
// The dye buffer runs at a fraction of screen resolution, so anything finer
// than a few screen pixels cannot be held and would only crawl and alias.
// --- ambient haze ------------------------------------------------------------
// A standing baseline of smoke, so a new plume always has older smoke to fold
// into rather than expanding into a vacuum. Shearing, folding and mixing are
// what make a fluid read as a fluid, and none of them are visible unless there
// is something already there to be sheared.
//
// This is real dye in the buffer, not a painted haze in the composite: it has
// to be advected by the same velocity field as everything else, or it could
// not interact at all.
//
// It nonetheless appears to lie still, which is worth explaining because the
// two facts look contradictory. The patch pattern below is fixed in SCREEN
// space, and it is a birth rate rather than a quantity -- so dye flows through
// it continuously at the draught's speed while the pattern itself stays put.
// What you see standing still is the pattern; the smoke in it is moving.
//
// The velocity gate is the interesting part. Still air is not where velocity
// is zero -- it never is anywhere, since the standing draught converges on
// WIND/VEL_DECAY, about 43 sim units. It is where velocity is no higher than
// that baseline. So the threshold sits well above the draught: haze forms
// everywhere the air is merely drifting, and stops forming where a plume is
// actually driving, which lets a keystroke carve a clean path through the
// haze that then fills back in behind it.
const float AMBIENT_CEIL  = 2.5;   // density this layer settles towards
const float AMBIENT_RATE  = 0.8;   // how fast it gets there, per slowed second
const float AMBIENT_SCALE = 5.0;   // pattern features across the screen
const float AMBIENT_LO    = 0.44;  // the noise band that becomes haze
const float AMBIENT_HI    = 0.63;
const float AMBIENT_EDGE  = 0.09;  // how soft the edges of the band are
const float AMBIENT_DRIFT = 0.010; // how fast the pattern itself re-forms
const float AMBIENT_STILL = 120.0; // speed above which no haze is born

// How much smoke survives over a glyph. Zero -- which is what this was --
// stamps the letterforms out of the smoke exactly, and the result reads as
// a decal with letter-shaped holes punched in it rather than as smoke in
// front of text. A floor lets the plume thin over a letter instead of
// vanishing at it. Legibility barely moves: at the densities typing
// reaches this is around a tenth of the image over a glyph, and for the
// ambient layer it is a couple of percent.
const float GLYPH_FLOOR  = 0.30;

// The same idea for the green, but this one is not a floor on the result the
// way GLYPH_FLOOR is -- it multiplies the glow every step, and the solver
// steps thirty times a second (half of a 60Hz display; the gate is on frame
// parity, so this follows the panel). At 0.55 that was still a million-fold
// attenuation inside a second, which is not thinning, it is deletion: glow
// rising off a word hit
// the line of text above it and was annihilated along the top edge of that
// line. Since a row of letters dilates into a mask that runs unbroken for
// about fifty pixels, what you saw was the plume cut off along a straight
// horizontal line -- the flat top above the spinner.
//
// Near one, it reads as what it was always meant to be. The glow's own
// half-life is about sixteen steps, so 0.96 costs it roughly half again while
// it sits over text: the letters dim it as it passes and it still comes out
// the other side. There is no hard iso-line left for the mask's edge to draw,
// and the flow already routes the green around the letters anyway, since
// sim-advect makes them obstacles.
const float GLOW_FLOOR   = 0.96;

// ...but not on the letters it was born on. Those are its own, and cutting a
// word out of the glow it is producing is what made the spinner look
// stencilled. Age separates the two cases at no cost: green sitting on its
// source is reborn every step so its age stays at zero, and anything it has
// drifted onto since is older than this. Under GLOW_OWN the glyphs are
// ignored, past it they thin the green like any other smoke.
const float GLOW_OWN     = 0.10;

const float MOTTLE       = 0.60;   // 0 = smooth puff, 1 = holes in it
const float MOTTLE_SCALE = 30.0;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i),               hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Two octaves, so the blobs have blobs. Offset per puff by the time of the
// write that made it, which is fixed for as long as that puff is emitting --
// so the pattern holds still while the puff forms, and the next puff gets a
// different one instead of stamping the same shape again.
// Rotated gradient of vnoise, and the gradient is taken analytically: the
// interpolant is a known polynomial of the four corner hashes, so its
// derivative costs the same four hashes as the value does. This used to be
// central differences -- four vnoise calls, sixteen hashes -- per curl, two
// curls a texel. Same field to a part in ten thousand, a quarter of the work.
vec2 curl2(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u  = f * f * (3.0 - 2.0 * f);
    vec2 du = 6.0 * f * (1.0 - f);
    float a = hash21(i), b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0)), d = hash21(i + vec2(1.0, 1.0));
    float k = a - b - c + d;
    float gx = du.x * ((b - a) + k * u.y);
    float gy = du.y * ((c - a) + k * u.x);
    return vec2(gy, -gx);
}

vec2 wisp(vec2 uv, float aspect) {
    vec2 q = vec2(uv.x * aspect, uv.y * WISP_TALL) * WISP_SCALE;
    vec2 a = curl2(q       + vec2(0.0,  iTime * WISP_DRIFT));
    vec2 b = curl2(q * 2.1 + vec2(3.7,  iTime * WISP_DRIFT * 1.6));
    return (a * 0.7 + b * 0.3) * WISP_FORCE;
}

float mottle(vec2 uv, float aspect) {
    vec2 q = vec2(uv.x * aspect, uv.y) * MOTTLE_SCALE
           + vec2(iTimeWriteHead * 7.3, iTimeWriteHead * 3.1);
    float n = vnoise(q) * 0.65 + vnoise(q * 2.3) * 0.35;
    return mix(1.0 - MOTTLE, 1.0 + MOTTLE, n);
}

// The strongest green anywhere in the cell whose centre is `c`. Two taps: a
// glyph is not guaranteed to have ink at its middle, and the lower one picks
// up the ones that sit low in the cell.
// --- the glyph mask ----------------------------------------------------------
// This used to be read out of the sim buffer's alpha, where sim-advect puts it
// for the velocity field to collide against. That buffer runs at 0.125 scale
// -- one texel per eight screen pixels -- so a glyph is about two texels by
// four in it. Fine for stopping the flow, but read back here it is a chunky
// rectangle around each letter rather than the letter, and that is the box you
// can see printed into the smoke.
//
// It costs five taps to work it out locally instead, at this pass's own 0.35
// scale, which is three times finer. Same test sim-advect uses, so the two
// masks still agree about where a glyph is.
// Kept identical to the copy in sim-advect.glsl on purpose. The two masks have
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
float glyphCover(vec2 uv) {
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

// The cell's key, signed (+green, -red), as sim-advect worked it out this
// step. It sits in the sim buffer's alpha, packed with the glyph mask, in
// the texel under the cell's centre. A sim texel is eight pixels and a cell
// is wider than that, so the texel whose centre is nearest the cell's centre
// is inside the cell, and it holds that cell's answer, not a neighbour's.
// texelFetch, not texture: bilinear would blend in the cell next door.
float cellGreen(vec2 c) {
    ivec2 t = ivec2(floor(c * vec2(textureSize(iChannel1, 0))));
    float a = texelFetch(iChannel1, t, 0).a;
    return (a > 3.5 ? a - 4.0 : a) - 1.5;
}

// Distance before greenness. The distance is arithmetic and the greenness is
// a fetch, and the search box below has to be wide enough for the widest
// ball, so for any given texel most of the cells in it are out of range --
// about five of the twenty-one actually reach. Asking the cheap question
// first makes the others cost nothing at all.
float ball(vec2 uv, vec2 c, float R) {
    // R is the cell width; the ellipse is BALL_RX by BALL_RY of it.
    float d = length((uv - c) * iResolution.xy / (R * vec2(BALL_RX, BALL_RY)));
    float f = 1.0 - smoothstep(BALL_CORE, 1.0, d);
    if (f <= 0.0) return 0.0;
    return cellGreen(c) * f;
}

// .x: the signed colour key (+green, -red). .y: the white edge key.
vec2 emitter(vec2 uv) {
    vec2 cellPx = iWriteHead.zw;
    if (cellPx.x <= 0.0) cellPx = CELL_FALLBACK;
    vec2 cellUV = cellPx / iResolution.xy;

    float R = cellPx.x;
    vec2  idx = floor(uv / cellUV);
    float w = 0.0;

    // Every cell whose ball can reach this texel: BALL_RX cells across, and
    // one row either side (BALL_RY cell widths is under a row's height).
    //
    // The four corners of that box used to be skipped, on the assumption that
    // a cell two across AND one down was too far to matter. At the current
    // radius it is not: the nearest corner of such a cell comes within 27px of
    // a texel, against a reach of 28, so a ball sitting there was clipped
    // against a boundary the loop drew rather than its own falloff. They cost
    // nothing now that `ball` rejects on distance before it reads anything.
    float k = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -3; i <= 3; i++) {
            vec2 c = (idx + vec2(float(i), float(j)) + 0.5) * cellUV;
            if (any(lessThan(c, vec2(0.0))) || any(greaterThanEqual(c, vec2(1.0)))) {
                // off the pane: an edge cell, white
                float d = length((uv - c) * iResolution.xy / (R * vec2(BALL_RX, BALL_RY)));
                w = max(w, (1.0 - smoothstep(BALL_CORE, 1.0, d)) * EDGE_KEY);
                continue;
            }
            float b = ball(uv, c, R);
            if (abs(b) > abs(k)) k = b;   // max by magnitude, sign rides along
        }
    }
    return vec2(k, w);
}

float smokeGate() {
    if (iWriteHead.z <= 0.0) return 0.0;
    // The hash gate first: it costs no texture reads and rejects most
    // writes, so the three colour taps below only happen on the small
    // fraction of writes that could still puff.
    float r = fract(sin(iTimeWriteHead * 91.7) * 43758.5453);
    if (r >= SMOKE_CHANCE) return 0.0;
    vec2 c = vec2(iWriteHead.x + iWriteHead.z * 0.5,
                  iWriteHead.y - iWriteHead.w * 0.5) / iResolution.xy;
    vec2 step_x = vec2(iWriteHead.z * 0.28, 0.0) / iResolution.xy;
    float m = max(max(sat(texture(iChannel0, c).rgb),
                      sat(texture(iChannel0, c + step_x).rgb)),
                  sat(texture(iChannel0, c - step_x).rgb));
    return smoothstep(SAT_MIN, SAT_MIN + 0.10, m);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 dts = 1.0 / vec2(textureSize(iChannel2, 0));
    vec2 sts = 1.0 / vec2(textureSize(iChannel1, 0));
    vec2 uv  = fragCoord * dts;

    // Odd frame: nothing steps, so hand back what is already here.
    if ((iFrame & 1) != 0) { fragColor = texture(iChannel2, uv); return; }
    float dt = min(iTimeDelta, DT_MAX) * SIM_STRIDE * TIME_SCALE;

    // Velocity is in sim-grid units, so the backward trace steps by the SIM
    // texel even though this pass writes the finer dye grid. The glyph mask
    // comes off the same tap, in alpha.
    vec4 s = texture(iChannel1, uv);
    vec2 vel = s.rg;

    // What is sitting here now. Used by both the advection correction below
    // and the glow, so it is one tap serving two purposes.
    vec4 here = texture(iChannel2, uv);

    // MacCormack: forward, then back along the velocity found at the point we
    // landed on, and correct by the error the round trip reveals.
    vec2  back = uv - dt * vel * sts;
    float fwd  = texture(iChannel2, back).r;
    vec2  velB = texture(iChannel1, back).rg;
    float rt   = texture(iChannel2, back + dt * velB * sts).r;

    // Widened from (0.35, 0.65). The mask comes off a dilated glyph
    // coverage, and a narrow ramp on it gives an edge as crisp as the
    // glyph itself -- which is the other half of why the cut looked
    // machined.
    float cover = glyphCover(uv);
    float clear = 1.0 - smoothstep(0.10, 0.90, cover);

    // The glow gets a tighter reading of the same coverage. The ramp above
    // starts at a tenth, which is deliberately generous -- it is what keeps the
    // smoke from being cut by a crisp letter-shaped edge. But generous plus a
    // dilation, at this pass's scale, means the gaps between letters fill in:
    // a dense line of text stops being letters and becomes one solid bar, and
    // the glow drifting up into it gets clipped along a hard horizontal line.
    // Asking for near-full coverage instead leaves those gaps open.
    float clearG = 1.0 - smoothstep(0.30, 1.00, cover);
    float dye = fwd + MACCORMACK * clear * (here.r - rt);
    dye = clamp(dye, min(fwd, here.r), max(fwd, here.r));
    dye *= (1.0 - DYE_DECAY * dt);

    // The green is smoke now, carried exactly the way the smoke above it is.
    // It used to be gathered from four bilinear taps around the traced point,
    // and that gather is a diffusion operator -- it destroyed structure about
    // as fast as the flow could create it, which is the whole reason the green
    // read as a soft blob while the grey beside it read as smoke. Same
    // MacCormack correction, same velocity field, same limiter. It also costs
    // one tap less than the gather did.
    //
    // The only thing it has of its own is the lift: straight up, one constant.
    // FIRE_RISE's note says why it is not a function of anything.
    //
    // vel is used exactly as the solver made it, walls included. Inside a
    // glyph it is zero, so there the lift is the whole velocity and the glow
    // rises straight through; outside one it follows the flow. That is all
    // the porosity there is, and it is the part that works. The earlier
    // vel * (1 - obs) scaling only differed from this in the mask's soft
    // fringe, and there it cost the field its divergence-freeness.
    vec2  swirl = wisp(uv, iResolution.x / iResolution.y);
    vec2  gvel  = vel + FIRE_DIR * FIRE_RISE + swirl;
    vec2  gback = uv - dt * gvel * sts;
    vec4  gsrcS = texture(iChannel2, gback);
    vec2  gvelB = texture(iChannel1, gback).rg + FIRE_DIR * FIRE_RISE + swirl;
    float grt   = texture(iChannel2, gback + dt * gvelB * sts).g;

    // Damped by the glow's own mask, not the smoke's. This read `clear` --
    // the generous ramp, the one that exists to keep a crisp letter-shaped
    // edge out of the grey -- and that mask runs unbroken for about fifty
    // pixels along a line of text. So the green's sharpening was being
    // switched off in bars that reach well past the letters into empty space,
    // and the correction changing abruptly across a straight line is a
    // straight line you can see, standing in nothing.
    //
    // The damping is there to stop the correction ringing against a
    // discontinuity, and the green no longer has one: GLOW_FLOOR barely
    // touches it and the letters are porous to it now. clearG is what the
    // rest of the glow reads, and it follows the letters rather than the row.
    float glow = gsrcS.g + GLOW_SHARPEN * clearG * (here.g - grt);
    glow = clamp(glow, min(gsrcS.g, here.g), max(gsrcS.g, here.g));
    glow *= (1.0 - GLOW_DECAY * dt);
    float age = gsrcS.b + dt;

    // Green is a source. Inside a glyph the velocity is zero, so glow born on
    // a letter cannot be blown off it -- it piles up there and spreads out
    // around the edges, which is exactly the shape a halo wants.
    // Green is a source, and what it emits is newborn: the fresh emission
    // pulls the age at this texel back towards zero in proportion to how
    // much of the glow here is new, so a letter that keeps shimmering keeps
    // restarting the burst around itself.
    vec2  em    = emitter(uv) * GLOW_AMT * dt
                * mottle(uv, iResolution.x / iResolution.y);
    float born  = em.x;            // signed: green or red
    float bornW = em.y;            // white, from the edges; positive
    glow += born + bornW;
    float fracC = clamp(abs(born) / max(abs(glow), 1e-4), 0.0, 1.0);
    float fracW = clamp(bornW     / max(abs(glow), 1e-4), 0.0, 1.0);
    age = mix(age, 0.0, fracC + fracW);
    float white = gsrcS.a;
    white = mix(white, 0.0, fracC);
    white = mix(white, 1.0, fracW);

    // What the air at this texel will still take, for both write-head
    // injections below. Per texel rather than global: the thick middle of a
    // plume stops accepting while its own fringe still lights up, so a burst
    // spreads outward instead of just getting denser in place.
    float appetite = exp(-max(here.r, 0.0) / WRITE_SAT);
    float wgain = writeGain();

    if (iWriteHead.z > 0.0) {
        float hit = exp(-max(iTime - iTimeWriteHead, 0.0) / 0.12);
        if (hit > 0.01) {
            float aspect = iResolution.x / iResolution.y;
            vec2 c = vec2(iWriteHead.x + iWriteHead.z * 0.5,
                          iWriteHead.y - iWriteHead.w * 0.5) / iResolution.xy;
            vec2 p = (uv - c) * vec2(aspect, 1.0);
            dye += exp(-dot(p, p) / SPLAT_RADIUS) * DYE_AMT * hit * SIM_STRIDE
                 * appetite * wgain;
        }
    }

    // The focus burst.
    if (iFocus != 0 && iCursorVisible != 0 && iCurrentCursor.z > 0.0) {
        float hit = exp(-max(iTime - iTimeFocus, 0.0) / FOCUS_PUFF_TAU);
        if (hit > 0.01) {
            float aspect = iResolution.x / iResolution.y;
            vec2 c = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5,
                          iCurrentCursor.y - iCurrentCursor.w * 0.5)
                   / iResolution.xy;
            vec2 p = (uv - c) * vec2(aspect, 1.0);
            dye += exp(-dot(p, p) / FOCUS_PUFF_RADIUS) * FOCUS_PUFF * hit
                 * SIM_STRIDE * mottle(uv, aspect);
        }
    }

    // The matching half of the puff: the ink the updraft in sim-advect has
    // something to lift.
    float puff = smokeGate();
    if (puff > 0.0) {
        float hit = exp(-max(iTime - iTimeWriteHead, 0.0) / 0.22);
        if (hit > 0.01) {
            float aspect = iResolution.x / iResolution.y;
            vec2 c = vec2(iWriteHead.x + iWriteHead.z * 0.5,
                          iWriteHead.y - iWriteHead.w * 0.5) / iResolution.xy;
            vec2 p = (uv - c) * vec2(aspect, 1.0);
            dye += exp(-dot(p, p) / SMOKE_RADIUS) * SMOKE_AMT * puff * hit
                 * SIM_STRIDE * mottle(uv, aspect) * appetite * wgain;
        }
    }

    // --- the ambient layer ---------------------------------------------------
    // Added last, so everything above has already been advected: this tops the
    // layer back up in place rather than injecting smoke that then gets moved.
    {
        float aspect = iResolution.x / iResolution.y;
        vec2 q = uv * vec2(aspect, 1.0) * AMBIENT_SCALE
               + vec2(0.0, iTime * AMBIENT_DRIFT);
        float n = vnoise(q) * 0.65 + vnoise(q * 2.3) * 0.35;

        // A BAND of noise values rather than everything above a threshold.
        // The set of points where a smooth field sits near one level is a
        // contour, so this picks out wandering filaments -- which is what
        // reads as "patterns here and there" -- where a plain threshold
        // gives solid blobs with the whole high side filled in.
        float pool = smoothstep(AMBIENT_LO - AMBIENT_EDGE,
                                AMBIENT_LO + AMBIENT_EDGE, n)
                   * (1.0 - smoothstep(AMBIENT_HI - AMBIENT_EDGE,
                                       AMBIENT_HI + AMBIENT_EDGE, n));

        // Only where the air is drifting rather than being driven.
        float calm = 1.0 - smoothstep(AMBIENT_STILL * 0.45, AMBIENT_STILL,
                                      length(vel));

        // Approach the ceiling instead of accumulating: where the layer is
        // already at strength this adds nothing, so a plume's own density is
        // never topped up by it and typing smoke stays clearly denser.
        float room = max(AMBIENT_CEIL - dye, 0.0);
        dye += AMBIENT_RATE * pool * calm * room * dt;
    }

    // Keep the ink out of the glyphs, and hand the composite the same mask
    // so it can find the text without a pristine image to key against.
    // The smoke is kept out of the glyphs; the glow is not, because a glow
    // that stops at the letter's edge is not a glow.
    float own = 1.0 - smoothstep(0.0, GLOW_OWN, age);
    float gclear = mix(clearG, 1.0, own);
    fragColor = vec4(max(dye * mix(GLYPH_FLOOR, 1.0, clear), 0.0),
                     glow * mix(GLOW_FLOOR, 1.0, gclear),   // signed: -red
                     clamp(age, 0.0, AGE_MAX),
                     clamp(white, 0.0, 1.0));
}
