#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- composer emptiness against a REAL rendered pane (task fm-composer-nbsp) --
#
# Claude Code 2.1.220 renders its empty composer as the agent prompt glyph `❯`
# followed by U+00A0 NO-BREAK SPACE, not an ASCII space. Captured from three
# live panes with `tmux capture-pane -p -t <pane> | cat -A`, which showed the
# composer row as the bytes `M-bM-^]M-/M-BM- ` (E2 9D AF C2 A0). Every fixture
# below is built from those exact bytes rather than a hand-typed approximation,
# because the whole defect was that a hand-typed ASCII space passed while what
# the harness actually renders did not.
#
# This runs against a real tmux pane on purpose: bin/fm-send.sh and the away-mode
# escalation injector both act on fm_tmux_composer_state's verdict, and the
# padding survived every ASCII-only unit fixture the suite had.
COMPOSER_WINDOW="fm-smoke-composer"
COMPOSER_TARGET="$SESSION:$COMPOSER_WINDOW"
NBSP=$'\xc2\xa0'

# wait_for_composer_render <expected-cursor-y> <expected-bytes> - block until the
# fixture pane has ACTUALLY drawn <expected-bytes> and parked its cursor on
# <expected-cursor-y>. Leaves the last observed capture in RENDER_SEEN / the last
# cursor row in RENDER_CY so a timeout can report what the pane really showed.
#
# Both halves are load-bearing. The byte check proves the whole fixture reached
# the screen, trailing U+00A0 included (tmux's capture keeps it: it is not an
# ASCII space, so the trailing-whitespace trim leaves it alone). The cursor check
# proves the fixture's own cursor-positioning escape has been processed too - the
# bordered fixtures end in `ESC[2A`, and a capture taken between the bottom
# border and that escape would leave the cursor below the box, where the reader
# finds no containing box at all.
wait_for_composer_render() {  # <expected-cursor-y> <expected-bytes>
  local want_cy=$1 want_text=$2 i=0
  RENDER_SEEN=
  RENDER_CY=
  while [ "$i" -lt 100 ]; do
    RENDER_CY=$(tmux display-message -p -t "$COMPOSER_TARGET" '#{cursor_y}' 2>/dev/null || true)
    RENDER_SEEN=$(tmux capture-pane -p -t "$COMPOSER_TARGET" -S 0 -E - 2>/dev/null || true)
    if [ "$RENDER_CY" = "$want_cy" ]; then
      case "$RENDER_SEEN" in
        *"$want_text"*) return 0 ;;
      esac
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# composer_state_is <label> <row-bytes> <cursor-y> <expected> - render <row-bytes>
# as the only content of a fresh pane and hold the cursor on the composer row
# with a sleep, so the reader sees a settled composer row exactly as it would on
# a live agent.
#
# The verdict is read ONCE, and only after the pane is proven to have rendered
# the fixture. It deliberately does NOT poll until the verdict happens to equal
# the expectation: a pane that has not drawn yet has no box, no composer edge and
# an empty cursor row, which classifies `empty` - so a poll-to-match loop passes
# every `empty` assertion on iteration 0, before `cat` has written a byte. Those
# are exactly the assertions that prove the U+00A0 padding fix (the content
# classifier for the bare rows, the box-geometry blank-interior test for the
# bordered one), and a test that cannot fail is the same mistake this task
# exists to correct: the pre-existing suite passed the whole time the bug was
# live. `pending` and `unknown` are never produced by a blank pane, so they were
# never vacuous, and they keep the same meaning under the stricter gate.
#
# The expected bytes are derived from the fixture itself (its own bytes, minus
# the CSI sequences a capture does not show) rather than hand-typed, so the
# synchronization can never drift from what is being asserted.
composer_state_is() {
  local label=$1 row=$2 want_cy=$3 want=$4 rendered got
  rendered=$(printf '%s' "$row" | fm_composer_strip_ansi)
  printf '%s' "$row" > "$SHIM_DIR/composer-row.bin"
  tmux kill-window -t "$COMPOSER_TARGET" 2>/dev/null || true
  tmux new-window -d -t "$SESSION" -n "$COMPOSER_WINDOW" \
    "cat '$SHIM_DIR/composer-row.bin'; sleep 300" \
    || fail "could not create the composer fixture window"
  wait_for_composer_render "$want_cy" "$rendered" \
    || fail "the composer fixture ($label) never rendered: expected cursor row $want_cy and bytes"$'\n'"$(printf '%s' "$rendered" | cat -A)"$'\n'"but the pane showed cursor row '${RENDER_CY:-<unreadable>}' and"$'\n'"$(printf '%s' "$RENDER_SEEN" | cat -A)"
  got=$(fm_tmux_composer_state "$COMPOSER_TARGET")
  [ "$got" = "$want" ] \
    || fail "real tmux composer row ($label) read '$got', expected '$want'"$'\n'"$(printf '%s' "$RENDER_SEEN" | cat -A)"
}

# The exact observed empty row: agent glyph + U+00A0, styled as claude emits it.
composer_state_is "claude empty composer: ❯ + U+00A0" $'\033[39m❯'"$NBSP" 0 empty
# The codex agent glyph with the same padding.
composer_state_is "codex empty composer: › + U+00A0" $'\033[39m›'"$NBSP" 0 empty
# Real typed text must still defer, including text that CONTAINS a no-break
# space - the trim is leading/trailing only, never a content-stripping pass.
composer_state_is "typed text after the glyph" $'\033[39m❯ fix findings 1 and 3' 0 pending
composer_state_is "typed text containing U+00A0" $'\033[39m❯ hello'"$NBSP"'world' 0 pending
composer_state_is "typed text right after U+00A0" $'\033[39m❯'"$NBSP"'hello' 0 pending
# The dead-shell safety boundary is unchanged by the wider trim.
composer_state_is "bare dead-shell prompt" '$' 0 unknown

# A BORDERED composer padded the same way. This is a second, independent layer:
# the box geometry check measures whether a content row's interior is blank, and
# an ASCII-only test there rejects a U+00A0-padded interior, marks the geometry
# ambiguous, and degrades the verdict to `unknown` even once the content
# classifier is correct. `\033[2A` parks the cursor back on the content row so
# the reader sees the same structure a live agent shows.
BOX_EMPTY="╭────────────╮"$'\n'"│ ❯$NBSP         │"$'\n'"╰────────────╯"$'\n'$'\033[2A'
BOX_TEXT="╭────────────╮"$'\n'"│ ❯ ship it  │"$'\n'"╰────────────╯"$'\n'$'\033[2A'
composer_state_is "bordered composer: ❯ + U+00A0" "$BOX_EMPTY" 1 empty
composer_state_is "bordered composer with text" "$BOX_TEXT" 1 pending
tmux kill-window -t "$COMPOSER_TARGET" 2>/dev/null || true
pass "real tmux: a composer padded with U+00A0 reads empty, while real typed text (even containing U+00A0) stays pending"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

cleanup_all
trap - EXIT
