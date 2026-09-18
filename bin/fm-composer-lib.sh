#!/usr/bin/env bash
# bin/fm-composer-lib.sh - the ONE fleet-wide owner of composer-content
# classification, shared by every session-provider adapter: the tmux path
# through bin/fm-tmux-lib.sh, and bin/backends/{herdr,orca,cmux}.sh directly.
#
# WHY THIS EXISTS (task fm-composer-shellglyph-safety): the four adapters each
# carried their own copy of the "is this composer row empty / pending / not an
# agent composer" decision, and the copies drifted. The dangerous drift: a BARE
# shell prompt glyph (`>`, `$`, `%`, `#`) - what a pane shows once its agent has
# exited to a plain login shell - was treated as an empty, ready-to-inject
# AGENT composer. The away-mode escalation injector (bin/fm-supervise-daemon.sh)
# reads composer-emptiness to decide whether a pane is a safe injection target,
# so a dead-shell pane misread as "empty" meant an escalation could be typed
# into (and, worst case, executed by) that shell. Consolidating the one decision
# here means the safety rule cannot silently drift across adapters again.
#
# THE SAFETY RULE this owner enforces: a bare shell prompt glyph is a genuine
# empty agent composer ONLY when it appears INSIDE a real agent-composer
# container - a bordered composer box, where the harness draws its own prompt
# glyph (e.g. claude's older `| > ... |`). On a bare, unstructured row it is a
# dead-shell prompt and is NEVER "empty"; it classifies as `unknown` (not a safe
# injection target). The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a
# genuine empty agent composer either way, bordered or bare - including when the
# harness pads that otherwise-empty row with non-ASCII whitespace, which
# FM_COMPOSER_WS and fm_composer_trim_ws below define and remove.
#
# GHOST/PLACEHOLDER TEXT is the other half of this owner (task
# afk-herdr-false-pending): a harness fills an otherwise-empty composer with
# de-emphasized ghost text - claude's rotating prompt suggestion, codex's idle
# suggestion, grok's placeholder - which a plain capture cannot tell apart from
# text a human typed, so the away-mode injector reads the idle pane as "pending
# input" and defers every escalation (the overnight wedge that motivated this
# consolidation). fm_composer_strip_ghost is the ONE ANSI-aware extractor of
# "real typed content": it drops every de-emphasized run - dim/faint (SGR 2, how
# claude and codex render ghost text) AND a dark/muted TRUECOLOR foreground (how
# grok renders placeholder/hint text) - and keeps only normal-intensity,
# normally-coloured text. Consolidating it here means the two ANSI-capable
# adapters (tmux via bin/fm-tmux-lib.sh, herdr via bin/backends/herdr.sh) cannot
# drift into per-harness one-off strips again; the previous herdr-only faint
# byte-pattern check missed claude's own dim ghost (its prompt glyph is not
# bold-wrapped) and no adapter covered grok's truecolor placeholder at all.
#
# Each adapter still owns its own CAPTURE and structural row-finding, because
# those use genuinely different primitives (tmux's visible-pane box scan,
# herdr's ANSI tail scan, orca/cmux's plain read-screen). Once an adapter has a
# candidate composer row it hands the RAW styled row to
# fm_composer_strip_ghost for the real-typed-content extraction, strips the box
# borders, trims, and hands the result plus a <bordered> flag to
# fm_composer_classify_content for the shared
# empty|pending|unknown verdict. orca/cmux read a plain (unstyled) screen so
# they have no ghost styling to strip and rely on the idle-placeholder match
# below. Re-sourcing is a cheap idempotent redefinition, so this file needs no
# include guard (matching bin/fm-tmux-lib.sh).

# FM_COMPOSER_WS / fm_composer_trim_ws: the ONE fleet-wide definition of the
# padding a TUI may draw around an otherwise-empty composer, and the trim that
# removes it. Every adapter used to re-roll the same ASCII-only trim idiom
# (`${s#"${s%%[![:space:]]*}"}`) before handing content to the classifier below;
# that idiom resolves `[:space:]` against the ambient locale, and glibc's UTF-8
# locales deliberately EXCLUDE U+00A0 from the space class (it is non-breaking).
# Claude Code renders its empty composer as `❯` + U+00A0, so the no-break space
# survived the trim, read as content after the prompt glyph, and the genuinely
# empty composer classified `pending` (task fm-composer-nbsp). That silently
# broke both consumers of emptiness: bin/fm-send.sh could never confirm a submit
# and reported false delivery failures on messages that were in fact delivered,
# and the away-mode injector (bin/fm-supervise-daemon.sh) never saw an injectable
# pane and deferred every escalation until its max-defer alarm fired.
#
# WHAT IS IN THE SET, and why it is a class rather than the one byte observed.
# The padding is a harness RENDERING detail that can change between harness
# versions, so the detector is deliberately robust to the class instead of
# pinned to one sequence:
#   - ASCII space, tab, newline, carriage return, vertical tab, form feed. The
#     previous behavior, restated explicitly so the trim no longer depends on
#     the ambient locale's classification at all.
#   - Every non-ASCII Unicode White_Space character: U+0085 NEL, U+00A0 (the
#     observed one), U+1680 OGHAM SPACE MARK, U+2000-U+200A (the general
#     punctuation spaces, including U+2007 FIGURE SPACE), U+2028 LINE
#     SEPARATOR, U+2029 PARAGRAPH SEPARATOR, U+202F NARROW NO-BREAK SPACE,
#     U+205F MEDIUM MATHEMATICAL SPACE, U+3000 IDEOGRAPHIC SPACE. These are the
#     characters a TUI reaches for when it pads or aligns a row.
#   - The invisible zero-width formatters a terminal writer emits as padding or
#     a stray byte-order mark: U+200B ZERO WIDTH SPACE, U+2060 WORD JOINER,
#     U+FEFF ZERO WIDTH NO-BREAK SPACE. They occupy no cell, so a row carrying
#     only these is visually an empty composer.
# DELIBERATELY EXCLUDED: U+200C ZERO WIDTH NON-JOINER and U+200D ZERO WIDTH
# JOINER, which carry linguistic meaning inside real text (emoji sequences,
# Indic scripts) and are not a padding idiom; and U+2800 BRAILLE PATTERN BLANK,
# which is a printable character harnesses use to draw spinners, so trimming it
# could read a busy row as an empty composer.
#
# SCOPE: this is a LEADING/TRAILING trim only, never a content-stripping pass.
# A no-break space INSIDE typed text is real content and must keep the row
# `pending`: `❯<U+00A0>hello` and `❯ hello<U+00A0>world` are text, not an empty
# composer. Only padding at the edges of an otherwise-contentless row is removed.
#
# The set is written as exact UTF-8 BYTE sequences and removed by literal prefix
# and suffix expansion, never through a `[...]` bracket expression or a `?`
# wildcard. Both of those are locale-dependent and would risk splitting a
# multibyte glyph under LC_ALL=C. Literal whole-sequence removal is exact in
# either locale, because a complete UTF-8 sequence is never a prefix of, nor
# contained inside, a different character's encoding.
FM_COMPOSER_WS=(
  ' ' $'\t' $'\n' $'\r' $'\v' $'\f'
  $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80'
  $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83'
  $'\xe2\x80\x84' $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87'
  $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a'
  $'\xe2\x80\xa8' $'\xe2\x80\xa9' $'\xe2\x80\xaf'
  $'\xe2\x81\x9f' $'\xe3\x80\x80'
  $'\xe2\x80\x8b' $'\xe2\x81\xa0' $'\xef\xbb\xbf'
)

# fm_composer_trim_ws_var: strip every leading and trailing FM_COMPOSER_WS
# sequence from <text> and leave the result in FM_COMPOSER_TRIMMED. This form
# PRINTS NOTHING on purpose: the structural row scans in bin/fm-tmux-lib.sh and
# bin/backends/herdr.sh trim once per pane row on every supervision poll, and a
# command substitution there would add a fork per row. The outer loop repeats
# until a full pass changes nothing, so mixed padding (a space then a no-break
# space, say) is fully removed regardless of the order the sequences appear in.
fm_composer_trim_ws_var() {  # <text> -> sets FM_COMPOSER_TRIMMED
  # LC_ALL=C walks bytes. That is both faster than multibyte pattern matching in
  # a poll-path loop and MORE exact here: [:space:] becomes deterministically
  # ASCII instead of locale-defined, and the multibyte sequences below are
  # matched as whole literal byte strings either way.
  local LC_ALL=C s=$1 prev ws
  # Cheap ASCII pass first, then an early-out: non-ASCII padding can only be at
  # an edge if an edge BYTE is >= 0x80, which on an ordinary pane row it is not.
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  case $s in
    [$'\200'-$'\377']*|*[$'\200'-$'\377']) ;;
    *) FM_COMPOSER_TRIMMED=$s; return 0 ;;
  esac
  while :; do
    prev=$s
    for ws in "${FM_COMPOSER_WS[@]}"; do
      while [ "${s#"$ws"}" != "$s" ]; do s=${s#"$ws"}; done
      while [ "${s%"$ws"}" != "$s" ]; do s=${s%"$ws"}; done
    done
    [ "$s" = "$prev" ] && break
  done
  FM_COMPOSER_TRIMMED=$s
}

# fm_composer_trim_ws: the printing form of the trim above, for the one-shot call
# sites (and tests) where readability beats the fork a command substitution
# costs. The call site already forks to capture the output, so the wrapper adds
# nothing.
fm_composer_trim_ws() {  # <text> -> <text> without leading/trailing composer padding
  fm_composer_trim_ws_var "$1"
  printf '%s' "$FM_COMPOSER_TRIMMED"
}

# fm_composer_pad_to_space_var: replace every FM_COMPOSER_WS sequence anywhere in
# <text> with one ASCII space, leaving the result in FM_COMPOSER_PADDED. Used by
# the width-signature checks that ask "is this box row's interior blank?" - those
# compare column shapes rather than trimming, so padding has to be NORMALIZED to
# a space there instead of removed. Zero-width members of the class collapse to a
# space and U+3000 is double-width, so a box padded with those can still measure
# one column off and read ambiguous; that defers, which is the safe direction.
fm_composer_pad_to_space_var() {  # <text> -> sets FM_COMPOSER_PADDED
  local LC_ALL=C s=$1 ws
  # Same byte-wise early-out as the trim: no high byte anywhere means no
  # non-ASCII padding to normalize.
  case $s in
    *[$'\200'-$'\377']*) ;;
    *) FM_COMPOSER_PADDED=$s; return 0 ;;
  esac
  for ws in "${FM_COMPOSER_WS[@]}"; do
    case "$ws" in ' ') continue ;; esac
    s=${s//"$ws"/ }
  done
  # Read by bin/fm-tmux-lib.sh's geometry checks, not by this file.
  # shellcheck disable=SC2034
  FM_COMPOSER_PADDED=$s
}

# fm_composer_strip_ansi: drop every CSI escape sequence, leaving plain text.
# Used for STRUCTURAL row/shape detection, where ghost text must be KEPT so the
# composer box border or bare prompt glyph is still visible; content extraction
# uses fm_composer_strip_ghost instead. Reads the styled text on stdin and prints
# plain text (stdin-only, matching fm_composer_strip_ghost). The character class
# includes ':' so an ITU colon-form SGR (38:2::r:g:b) is stripped whole, not left
# with a dangling tail.
fm_composer_strip_ansi() {
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;:?]*[[:alpha:]]//g"
}

# fm_composer_strip_ghost: the ONE fleet-wide ANSI-aware extractor of "real typed
# content" from a captured, styled composer row. Reads the styled line on stdin
# (from `tmux capture-pane -e` or `herdr pane read --format ansi`) and prints the
# plain, non-ghost text on stdout, dropping:
#   - dim/faint runs (SGR 2): how claude and codex render ghost/suggestion text.
#     A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run.
#   - dark/muted TRUECOLOR foreground runs (SGR 38;2;r;g;b or the colon form
#     38:2::r:g:b) whose perceived luminance (0.299R + 0.587G + 0.114B) is below
#     FM_COMPOSER_GHOST_LUMA_MAX (default 128): how grok renders its placeholder
#     and hint text. A reset (SGR 0), a default-foreground (SGR 39), any base
#     foreground colour (30-37 / 90-97), or a lighter 38;2 foreground ends the
#     dark-foreground run. This assumes a DARK terminal theme, the firstmate
#     fleet reality, where real typed input is bright and only de-emphasised UI
#     is dark; the SGR-2 signal above stays theme-independent. A 256-colour
#     foreground (38;5;n) is NOT luminance-tested - it is palette-dependent and
#     no fleet harness uses it for ghost text, so it is kept (real text wins:
#     under-stripping merely defers, which the max-defer alarm surfaces, while
#     over-stripping would inject over real input).
# The dim/faint and dark-foreground states are tracked together as "de-emphasis";
# codes are processed left to right within a sequence, so "ESC[0;2m" reads as dim.
# LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and de-emphasised
# runs alike pass through or drop intact without locale-dependent classes.
fm_composer_strip_ghost() {
  LC_ALL=C awk -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    # fg38_is_dark: 1 when the SGR 38 foreground starting at param p is a
    # TRUECOLOR (38;2 / 38:2) whose luminance is below lumamax; 0 otherwise
    # (a 38;5 palette colour, a bright truecolor, or a malformed run).
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {           # colon form: whole colour in a[p]
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    {
      line = $0; out = ""; dim = 0; darkfg = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update de-emphasis
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0") { dim = 0; darkfg = 0 }
                else if (code == "22") dim = 0
                else if (code == "39") darkfg = 0
                else if (code + 0 >= 30 && code + 0 <= 37) darkfg = 0
                else if (code + 0 >= 90 && code + 0 <= 97) darkfg = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0 && darkfg == 0) out = out c   # keep only non-de-emphasised bytes
        i++
      }
      print out
    }
  '
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, or a structurally-identified bare AGENT
#              prompt row); 0 for a bare, unstructured row (e.g. tmux's raw
#              cursor line that carried no box border).
#   <content>  the candidate composer content, already border-stripped by the
#              caller. Leading and trailing padding is re-trimmed here through
#              fm_composer_trim_ws, so the verdict cannot depend on how
#              completely a caller trimmed first.
#   [idle_re]  optional per-harness idle-placeholder regex (e.g. grok's
#              "Type a message...") that reads as empty; matched both before and
#              after a leading prompt glyph is stripped, so a pattern written
#              with or without the glyph both land.
fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content]
  local bordered=$1 idle_re=${3:-} idle_case=${4:-sensitive} content plain_content
  # Normalize both inputs here rather than trusting the caller's trim: this is
  # the one place the empty-vs-pending verdict is decided, so it is the one
  # place the padding class has to be understood (see FM_COMPOSER_WS).
  fm_composer_trim_ws_var "$2"
  content=$FM_COMPOSER_TRIMMED
  fm_composer_trim_ws_var "${5:-$2}"
  plain_content=$FM_COMPOSER_TRIMMED
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    case "$plain_content" in
      '❯'|'›') printf 'empty'; return 0 ;;
      *) printf 'unknown'; return 0 ;;
    esac
  fi
  # A bare prompt glyph on its own row.
  case "$content" in
    '❯'|'›')
      # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
      printf 'empty'; return 0 ;;
    '>'|'$'|'%'|'#')
      # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  # Nothing on the row = empty composer.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder. The glyph is
  # removed as a literal, not through a `?` wildcard, so the removal is exact
  # whether or not the ambient locale reads `❯` as one character; whatever
  # separator the harness draws after it - an ASCII space, a no-break space, or
  # nothing - is then removed by the shared trim.
  case "$content" in
    '❯'*) content=${content#'❯'} ;;
    '›'*) content=${content#'›'} ;;
    '>'*) content=${content#'>'} ;;
    '$'*) content=${content#'$'} ;;
    '%'*) content=${content#'%'} ;;
    '#'*) content=${content#'#'} ;;
  esac
  fm_composer_trim_ws_var "$content"
  content=$FM_COMPOSER_TRIMMED
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}
