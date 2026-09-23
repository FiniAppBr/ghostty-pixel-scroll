#!/bin/sh
# What every split runs. Wraps the ssh to the VPS in a reconnect loop, so a
# dropped connection reopens the same pane instead of taking the split with
# it. Ghostty ends a surface when its command exits, and the command used to
# be ssh itself: anything that killed ssh killed the split.
#
# Each split claims a slot number for as long as it lives and hands it to
# claude-pane on the far side, which keeps one conversation id per slot. So a
# reconnect resumes the conversation that split already had, rather than
# starting fresh or landing in a neighbour's.
#
# A split's FIRST connection is deliberately not a resume, though: opening
# Ghostty should give you three empty panes, not three walls of yesterday's
# scrollback. Only the reconnects below resume, which is the case the slot
# exists for -- a dropped link should not cost you the conversation.
#
# No tmux and no mosh here, on purpose: both run in the alternate screen
# buffer, which leaves pixel-scroll with no scrollback to move through. See
# the `command` note in ./config.

HOST=hostinger
REMOTE=/usr/local/bin/claude-pane
SLOTS=${TMPDIR:-/tmp}/ghostty-panes

# Claim the lowest free slot. mkdir is atomic, so two splits opening at the
# same moment cannot take the same one. A slot whose owner is gone is reused.
mkdir -p "$SLOTS"
slot=""
n=1
while [ "$n" -le 9 ]; do
    d=$SLOTS/$n
    if mkdir "$d" 2>/dev/null; then
        # Claim it by writing the pid at once. A directory that exists with
        # no pid in it yet looks abandoned to nobody -- the branch below
        # requires a pid to consider stealing -- but the shorter that gap is,
        # the less there is to reason about.
        printf '%s\n' "$$" > "$d/pid"
        slot=$n
    else
        owner=$(cat "$d/pid" 2>/dev/null)
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            # Take the dead pane's slot by moving it aside first, not by
            # deleting it in place. `rm -rf` then `mkdir` is not atomic, and
            # the gap between them is real: another split starting in the
            # same instant can create and claim this exact directory, and
            # the rm then destroys the slot that split already took. The
            # victim's own `printf > .../pid` is what fails, with ENOENT,
            # which is how this showed up. A rename can only succeed for one
            # pane, and it cannot touch a directory somebody else has since
            # created in its place.
            if mv "$d" "$d.stale.$$" 2>/dev/null; then
                rm -rf "$d.stale.$$"
                if mkdir "$d" 2>/dev/null; then
                    printf '%s\n' "$$" > "$d/pid"
                    slot=$n
                fi
            fi
        fi
    fi
    [ -n "$slot" ] && break
    n=$((n + 1))
done

if [ -n "$slot" ]; then
    trap 'rm -rf "$SLOTS/$slot"' EXIT INT TERM
else
    slot=0
fi

mode=fresh
attempt=0
while :; do
    started=$(date +%s)
    ssh -t "$HOST" "$REMOTE" "$slot" "$mode"
    rc=$?
    mode=resume

    # A clean exit is the login shell on the far side being dismissed on
    # purpose. Honour it and let the split close.
    [ "$rc" -eq 0 ] && exit 0

    # A connection that stood up for a while then fell over is a fresh
    # failure, not an escalating one, so it retries immediately again.
    [ $(( $(date +%s) - started )) -gt 60 ] && attempt=0

    attempt=$((attempt + 1))
    delay=$((attempt * 2))
    [ "$delay" -gt 10 ] && delay=10

    printf '\n\033[2m[pane %s] connection ended (rc %s) - reconnecting in %ss, ctrl-c to stop\033[0m\n' \
        "$slot" "$rc" "$delay"
    sleep "$delay" || break
done

printf '\033[2m[pane %s] stopped reconnecting; local shell\033[0m\n' "$slot"
exec /bin/zsh -l
