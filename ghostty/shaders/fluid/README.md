# Fluid passes

Shared preamble, pasted into each fluid pass (Ghostty has no #include).

Channel convention for every pass in this set:
  iChannel0 = the terminal image, before any visible shader has run
  iChannel1 = sim buffer : rg = velocity, b = pressure, a = glyph mask
  iChannel2 = dye buffer : r = ink amount, a = 1 outside glyphs

The ink carries no colour of its own; composite.glsl colours it from
iPalette, so it follows whatever theme is loaded. The glyph mask is keyed
against iBackgroundColor for the same reason.

What moves the fluid: output landing (iWriteHead), the cursor jumping
(iCurrentCursor vs iPreviousCursor), scrolling text (iScrollVelocity, which
makes moving glyphs carry the flow rather than cut holes in it), the mouse,
a standing draught up and to the left (WIND, WIND_DIR) and extra lift where
there is ink (BUOYANCY, always straight up).

Smoke off Claude's output: sim-advect and dye-advect each decide, from the
same two gates, whether a given write puffs. The first gate is colour --
plain shell output is drawn in the near-grey default foreground, while
Claude's bullets and inline code are not -- and the second is a hash of
iTimeWriteHead, so only SMOKE_CHANCE of the qualifying writes fire. The
constants are duplicated across the two files and have to stay in step.

Dials worth knowing, all hot-reloadable (edit, then reload the config):
  sim-advect  WIND, WIND_DIR   the standing draught and its direction
  sim-advect  BUOYANCY         extra lift on ink, always straight up
  sim-advect  SMOKE_FORCE      the lift under one puff
  dye-advect  SMOKE_AMT        how much ink a puff releases
  both        SMOKE_CHANCE     how often a qualifying write puffs
  both        SAT_MIN          how colourful text must be to count

iResolution is the window size in every pass, including the ones that
render into a smaller buffer. A pass gets its own size from textureSize on
the channel it targets, and uses iResolution only to sample iChannel0,
which is always full resolution.

The glyph mask is not a buffer of its own. sim-advect computes it from
iChannel0 once per frame and parks it in the sim buffer's alpha, where the
projection passes read it off taps they were already making. Recomputing it
per pass instead would cost nine texture fetches per neighbour per Jacobi
sweep, which at twelve sweeps is most of the frame.

Twelve sweeps, not the usual twenty-plus: the pressure channel persists
across frames, so every frame starts from last frame's solution and only
has to catch up with what changed. Each sweep is a render pass, and on a
tile-based GPU the pass count matters more than the pixels in it, so this
is the first number to lower if it ever feels heavy.
