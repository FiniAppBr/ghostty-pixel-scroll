#!/bin/sh
# One Ghostty split -> one mosh session to the VPS, running claude in
# /opt/violaoacademy.
#
# This lives in a script rather than inline in `command =` because the
# --server value contains a space and has to survive as a single argument;
# going through the config parser and a shell wrapper made that fragile.
#
# mosh echoes typed characters locally instead of waiting ~48ms for the VPS,
# and reaches the server over the WireGuard tunnel (host `vps` = 10.8.0.1),
# so no mosh port is exposed publicly. MOSH_SERVER_NETWORK_TMOUT makes a
# session with no client exit after an hour, so quitting Ghostty does not
# leave servers running forever.
#
# Requires xterm-ghostty terminfo on the VPS. Ghostty's ssh-terminfo shell
# integration only wraps `ssh`, not mosh, so it was installed there once with:
#   TERMINFO=<app>/Contents/Resources/terminfo infocmp -x xterm-ghostty \
#     | ssh vps 'cat > /tmp/g.ti && tic -x /tmp/g.ti'
# If the VPS is rebuilt, re-run that or every split dies instantly.

LOG="$HOME/.config/ghostty/pane-launch.log"

# Keep the log from growing without bound.
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 131072 ] && : > "$LOG"

/opt/homebrew/bin/mosh \
  --predict=experimental \
  --server='MOSH_SERVER_NETWORK_TMOUT=3600 mosh-server' \
  vps -- /usr/local/bin/claude-pane 2>>"$LOG"
status=$?

[ "$status" -eq 0 ] && exit 0

# Something went wrong: say so and keep the split open rather than vanishing.
echo
echo "mosh exited with status $status — see $LOG"
echo
exec /bin/bash -l
