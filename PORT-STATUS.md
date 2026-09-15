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

`pixel-scroll`, `scroll-animation-duration` (see Config.zig for docs).

- `updateFrame` records the viewport's absolute row (`.screen` point of
  the viewport top). When it changes, the grid is offset by the distance
  moved, so content is drawn where the eye last saw it.
- The offset goes into the **projection matrix** (`projectionMatrix()`),
  not into the cell data. No cell-ABI change and no shader edits, so
  Metal and OpenGL both get it. The fork instead added a per-cell
  `offset_y_fixed`, which meant changing the Zig struct, the MSL shaders
  and the GLSL shaders together.
- `stepScrollAnimation()` decays the offset exponentially on wall-clock
  time, and `animationWake()` requests draws until it settles — reusing
  upstream's animation timer.

### Known limits (next steps)

1. **The offset is clamped to one cell.** We only draw the viewport's own
   rows, so any offset leaves that much background at one edge. Overscan
   rows above and below the viewport lift this.
2. **Scroll detection uses absolute `.screen` rows.** Once the scrollback
   is full, an evicted row cancels out an appended one, so output-driven
   scrolling stops animating at the limit. User scrolling is unaffected.
3. **Cursor animation isn't done.** It needs sub-cell cursor placement,
   which unlike the scroll offset does require a shader/ABI change.

## Building

The macOS app needs Xcode, which this machine doesn't have (Command Line
Tools only — `xcrun metal` is missing, so even `zig build test` can't get
past the metallib step). Hence `.github/workflows/build-macos-pixel-scroll.yml`,
which builds and uploads an unsigned, ad-hoc-signed Ghostty.app.

Locally, `zig build -Dtarget=aarch64-linux-gnu -Dapp-runtime=none` (Zig
0.16.0 at ~/.local/zig) type-checks the core through the OpenGL backend.
Note `-Dfont-backend=freetype` fails in upstream's own App.zig:85 —
use the default backend.
