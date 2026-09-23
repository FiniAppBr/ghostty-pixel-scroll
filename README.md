# Local setup

Config for this build and for the Claude Code sessions it runs, kept here so a
new machine or a wiped VPS can be put back the way it was.

The Ghostty *source* changes this config depends on (pixel-scroll, cursor
motion, text fade, custom-shader-buffer/pass, focus-follows-scroll,
initial-splits) are on branches `ci-pixel-scroll` and `fluid` of this repo.
This branch is public, so the VPS's Claude Code `settings.json` is NOT here
(it names the server and holds credentials); copy it from the VPS by hand.

## Laptop

| File | Goes to |
| :--- | :--- |
| `ghostty/config` | `~/.config/ghostty/config` |
| `ghostty/pane-connect.sh` | `~/.config/ghostty/pane-connect.sh` |
| `ghostty/pane-launch.sh` | `~/.config/ghostty/pane-launch.sh` (retired mosh launcher) |
| `ghostty/shaders/` (incl. `fluid/`) | `~/.config/ghostty/shaders/` |
| `ghostty/ssh-vps-dock-launch.sh` | `~/Applications/SSH VPS.app/Contents/MacOS/launch` |

`config` points `custom-shader` at absolute paths under
`/Users/luizpasqualefilho`. Change them if the home directory differs.

The only visible shader is `visible.glsl` (cursor halo + shimmer bloom + fluid
composite merged into one pass); the `fluid/` passes feed it through
`custom-shader-buffer`s. The other `.glsl` files are kept but not in the chain.

## Windows

Upstream Ghostty has no official Windows build, and none of this fork's keys
exist in a stock build -- it will open its config-error window. To reuse the
config on Windows:

- Comment out: `pixel-scroll`, `scroll-animation-*`, `cursor-animation-*`,
  `text-fade-duration`, `focus-follows-scroll`, `initial-splits`, and every
  `custom-shader-buffer` / `custom-shader-pass` / `custom-shader-pass-stride`.
  `visible.glsl` needs the fluid buffers, so point `custom-shader` at
  `cursor-halo.glsl` then `shimmer-bloom.glsl` instead (if the port supports
  shaders at all).
- Rewrite the absolute `/Users/luizpasqualefilho/...` paths.
- `command` runs `/bin/sh pane-connect.sh`; on Windows use `command = ssh
  hostinger` (with a `hostinger` entry in `~/.ssh/config`) or run the script
  under Git Bash / WSL.

## VPS

| File | Goes to |
| :--- | :--- |
| `vps/claude-pane` | `/usr/local/bin/claude-pane` (chmod +x) |
| `vps/themes/phosphor-pastel.json` | `~/.claude/themes/` |
| `vps/ccstatusline-settings.json` | `~/.config/ccstatusline/settings.json` |

`ccstatusline` is a separate install and is not restored by copying files:

    npm i -g ccstatusline

It is referenced by bare name from `statusLine` in the settings, so if the
binary goes missing the status line silently renders nothing rather than
erroring.

## How the colours fit together

The spinner is dark grey (`claude`) sweeping to phosphor green
(`claudeShimmer`), and `shimmer-bloom.glsl` keys on that green to bloom the
crest of the sweep. The two are a pair: recolour the shimmer in the theme and
the shader stops finding it, so `KEY_GREEN` has to move with it.

The same shader also repaints Claude Code's light blues to green. That is a
workaround, not a preference. Claude Code resolves a `codespan` colour by theme
*name*, and the lookup behind it only knows its six built-in presets — any
custom theme falls through to built-in dark, so the theme's own `permission`
override can never reach inline code. A palette remap used to cover it, but
`COLORTERM=truecolor` (set in `claude-pane`) means exact RGB rather than a
palette slot, so the repaint moved into the shader. Set `CODE_ENABLE = 0.0` to
turn it off and live with blue inline code.

`COLORTERM` is set in `claude-pane` rather than forwarded over ssh because
sshd is `AcceptEnv LANG LC_*` and drops it.
