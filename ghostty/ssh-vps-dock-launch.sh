#!/bin/sh
# Opens Ghostty. The three splits come from `initial-splits` in the config,
# and no `-n`, so the pinned Dock icon lights up instead of a second tile.
APP="$HOME/Applications/Ghostty.app"
[ -d "$APP" ] || APP="/Applications/Ghostty.app"
exec open -a "$APP"
