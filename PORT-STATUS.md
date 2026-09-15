# Smooth (pixel) scrolling for Ghostty

Branch `pixel-scroll`, on top of ghostty-org/ghostty `main` (1.3.2-dev).

## Why this isn't the fork's patch

parkers0405/ghostty-pixel-scroll diverged from upstream at 8d1d17e00
(2026-01-31); upstream has since moved 3,677 commits. Its net patch is
26,916 lines over 116 files, of which ~17,400 are a bundled Neovim GUI,
panel GUI, collab feature and Neovim profile system that have nothing to
do with scrolling.

A mechanical three-way port was tried first: 37 files applied cleanly, 16
conflicted (46 hunks), and 14 of those resolved fine. The remaining three
were not merges but re-implementations, because upstream rewrote exactly
what the patch is built on:

- the software draw timer the fork's frame pacing drives was **deleted**
  upstream in favour of the animation timer;
- `generic.zig` gained `syncDisplayLink` and a draw mutex, against which
  the fork replaces 238 lines of `drawFrame`;
- the row-building loop became `RowBuilder` + page-chunk iteration.

So the fork is kept as a design reference (`~/dev/fork-reference/`) and
the feature is written against the current renderer instead.

One useful finding from that attempt: the fork's `macos/Sources` diff is
+91/-79 of pure drift with **zero** scroll or animation code. The whole
feature is in the Zig core, so no Swift changes are needed.

## What's implemented

`pixel-scroll`, `scroll-animation-duration`, `scroll-animation-bounciness`,
`cursor-animation-duration`, `cursor-animation-bounciness` (see Config.zig
for docs).

### Motion

`animation.zig` holds a critically damped spring, the same model Neovide
and the fork use. It carries velocity, so a move eases in and out and a
second move part-way through the first blends with it rather than
restarting it. An earlier attempt decayed the offset exponentially
instead; it read as lag rather than as motion, and the difference is
plainly visible side by side with the fork.

### Scrolling

- `updateFrame` records the viewport's absolute row (`.screen` point of
  the viewport top). When it changes, the distance moved goes to the
  spring, so content is drawn where the eye last saw it and travels from
  there. This happens **before** the render state snapshot is built, not
  after: the snapshot is asked for exactly the rows this frame will slide
  into view.
- `RenderState.beginUpdate` takes an `Overscan`, and builds rows above and
  below the viewport. The renderer lags the snapshot by however many whole
  rows the scroll still has to travel and draws the remainder as a
  sub-cell offset, so a multi-row scroll animates the whole distance with
  two spare rows rather than one row per row travelled.
- The draw offset goes into the **projection matrix**
  (`projectionMatrix()`), not the cell data, so the vertices need no
  per-cell ABI change. The background shader maps screen pixels back to
  grid rows, so it gets the offset as a uniform (`grid_offset_y`) to undo.

### The cursor

- `CornerCursor` springs each of the cursor quad's four corners
  separately. The corners facing the way it is going arrive first, the
  ones behind hold back, so the cursor stretches out of the cell it left
  and gathers itself into the cell it lands on. This is Neovide's cursor,
  by way of the fork; a cursor that slides rigidly reads as a cursor
  that is late.
- The four corner offsets are uniforms, applied in the cell-text vertex
  shader to the cursor glyph only (`IS_CURSOR_GLYPH`), after the quad's
  own corner is worked out. The character underneath does not move.
- Cursor position is tracked in the **content**, not on screen, so
  scrolling the grid under the cursor is not mistaken for the cursor
  moving. A cursor that keeps its row on screen while the terminal
  scrolls — output at the bottom of the screen, every line — is carried
  by the grid, so it travels in one piece over the scroll's own duration
  rather than stretching on every line.

### Known limits

1. **Scroll detection uses absolute `.screen` rows.** Once the scrollback
   is full, an evicted row cancels out an appended one, so output-driven
   scrolling stops animating at the limit. User scrolling is unaffected.
2. **The character under the cursor inverts at the destination**, in one
   step, while the cursor is still on its way. Neovide does the same.
3. **Scroll distance is capped at one screen**, so paging to the top of
   the scrollback lands rather than flying the whole way.

## Building

The macOS app needs Xcode, which this machine doesn't have (Command Line
Tools only — `xcrun metal` is missing, so even `zig build test` can't get
past the metallib step). Hence `.github/workflows/build-macos-pixel-scroll.yml`,
which builds and uploads an unsigned, ad-hoc-signed Ghostty.app.

Locally, `zig build -Dtarget=aarch64-linux-gnu -Dapp-runtime=none` (Zig
0.16.0 at ~/.local/zig) type-checks the core through the OpenGL backend.
Note `-Dfont-backend=freetype` fails in upstream's own App.zig:85 —
use the default backend.
