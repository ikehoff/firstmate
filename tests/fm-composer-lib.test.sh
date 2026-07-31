#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
#
# The padding contract, task fm-composer-nbsp:
#   5. A composer whose only remaining content is LEADING/TRAILING padding is
#      empty, where padding is the FM_COMPOSER_WS class (bin/fm-composer-lib.sh)
#      and not merely ASCII whitespace. Claude Code renders its empty composer
#      as `❯` + U+00A0, which no locale's [:space:] class matches, so the
#      ASCII-only trim read the idle composer as `pending` - breaking submit
#      confirmation in bin/fm-send.sh and away-mode escalation injection.
#   6. Padding INSIDE real typed text is content, not padding: the trim is
#      leading/trailing only and must never turn typed text into `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Padding: non-ASCII whitespace around an otherwise-empty composer -------

# The exact bytes Claude Code 2.1.220 renders for an EMPTY composer, captured
# from three live panes with `tmux capture-pane -p -t <pane> | cat -A`:
#   M-bM-^]M-/M-BM-      = E2 9D AF (❯ U+276F) then C2 A0 (U+00A0 NO-BREAK SPACE)
# Written as raw byte escapes, not a typed character, so the fixture cannot
# silently degrade into an ASCII space the way the original suite's did.
CLAUDE_EMPTY_ROW=$'\xe2\x9d\xaf\xc2\xa0'
NBSP=$'\xc2\xa0'

test_observed_claude_empty_composer_is_empty() {
  local out
  out=$(classify 0 "$CLAUDE_EMPTY_ROW")
  [ "$out" = empty ] \
    || fail "the observed claude empty composer (❯ + U+00A0) must read empty, got '$out'"
  out=$(classify 1 "$CLAUDE_EMPTY_ROW")
  [ "$out" = empty ] \
    || fail "the observed claude empty composer inside a box must read empty, got '$out'"
  # The same padding after the codex agent glyph.
  out=$(classify 0 $'\xe2\x80\xba\xc2\xa0')
  [ "$out" = empty ] || fail "codex '›' + U+00A0 must read empty, got '$out'"
  out=$(classify 1 $'\xe2\x80\xba\xc2\xa0')
  [ "$out" = empty ] || fail "bordered codex '›' + U+00A0 must read empty, got '$out'"
  pass "fm_composer_classify_content: the real captured claude/codex empty composer (glyph + U+00A0) reads empty"
}

test_ascii_and_bare_glyph_cases_do_not_regress() {
  local out
  out=$(classify 0 '❯ '); [ "$out" = empty ] || fail "'❯ ' (ASCII space) should still read empty, got '$out'"
  out=$(classify 0 '❯');  [ "$out" = empty ] || fail "bare '❯' should still read empty, got '$out'"
  out=$(classify 0 '›');  [ "$out" = empty ] || fail "bare '›' should still read empty, got '$out'"
  out=$(classify 0 '   '); [ "$out" = empty ] || fail "an all-ASCII-space row should still read empty, got '$out'"
  out=$(classify 0 '❯ hello'); [ "$out" = pending ] || fail "'❯ hello' should still read pending, got '$out'"
  pass "fm_composer_classify_content: the ASCII-space and bare-glyph cases are unchanged"
}

# Every sequence FM_COMPOSER_WS deliberately includes. Padding a composer with
# any one of them, alone or after the prompt glyph, is still an empty composer:
# the detector is robust to the CLASS, not pinned to the one byte sequence the
# current claude build happens to emit.
test_every_included_padding_sequence_reads_empty() {
  local name seq out
  local -a cases=(
    'U+0085 NEL'                  $'\xc2\x85'
    'U+00A0 NO-BREAK SPACE'       $'\xc2\xa0'
    'U+1680 OGHAM SPACE MARK'     $'\xe1\x9a\x80'
    'U+2000 EN QUAD'              $'\xe2\x80\x80'
    'U+2003 EM SPACE'             $'\xe2\x80\x83'
    'U+2007 FIGURE SPACE'         $'\xe2\x80\x87'
    'U+200A HAIR SPACE'           $'\xe2\x80\x8a'
    'U+2028 LINE SEPARATOR'       $'\xe2\x80\xa8'
    'U+2029 PARAGRAPH SEPARATOR'  $'\xe2\x80\xa9'
    'U+202F NARROW NO-BREAK SPACE' $'\xe2\x80\xaf'
    'U+205F MEDIUM MATH SPACE'    $'\xe2\x81\x9f'
    'U+3000 IDEOGRAPHIC SPACE'    $'\xe3\x80\x80'
    'U+200B ZERO WIDTH SPACE'     $'\xe2\x80\x8b'
    'U+2060 WORD JOINER'          $'\xe2\x81\xa0'
    'U+FEFF ZERO WIDTH NBSP'      $'\xef\xbb\xbf'
  )
  local i=0
  while [ "$i" -lt "${#cases[@]}" ]; do
    name=${cases[$i]}; seq=${cases[$((i + 1))]}; i=$((i + 2))
    out=$(classify 0 "❯$seq")
    [ "$out" = empty ] || fail "'❯' padded with $name must read empty, got '$out'"
    out=$(classify 0 "$seq❯$seq")
    [ "$out" = empty ] || fail "'❯' surrounded by $name must read empty, got '$out'"
    out=$(classify 1 "$seq")
    [ "$out" = empty ] || fail "a bordered row of only $name must read empty, got '$out'"
    # Padding must never swallow real text that follows it.
    out=$(classify 0 "❯${seq}fix the build")
    [ "$out" = pending ] || fail "text after $name padding must read pending, got '$out'"
  done
  pass "fm_composer_classify_content: every FM_COMPOSER_WS sequence reads as padding, and never swallows text after it"
}

# The characters deliberately EXCLUDED from FM_COMPOSER_WS. ZWNJ and ZWJ carry
# linguistic meaning inside real text; U+2800 BRAILLE PATTERN BLANK is a
# printable glyph harnesses draw spinners with, so trimming it could read a busy
# row as an injectable empty composer.
test_excluded_sequences_are_not_padding() {
  local name seq out
  local -a cases=(
    'U+200C ZERO WIDTH NON-JOINER' $'\xe2\x80\x8c'
    'U+200D ZERO WIDTH JOINER'     $'\xe2\x80\x8d'
    'U+2800 BRAILLE PATTERN BLANK' $'\xe2\xa0\x80'
  )
  local i=0
  while [ "$i" -lt "${#cases[@]}" ]; do
    name=${cases[$i]}; seq=${cases[$((i + 1))]}; i=$((i + 2))
    out=$(classify 0 "❯$seq")
    [ "$out" = pending ] \
      || fail "$name is deliberately not padding and must keep the row pending, got '$out'"
  done
  pass "fm_composer_classify_content: ZWNJ, ZWJ and the braille blank are excluded from the padding class"
}

# The scope boundary the fix must not cross: a no-break space INSIDE typed text
# is real content. Only edge padding is removed.
test_padding_inside_real_text_stays_pending() {
  local out
  out=$(classify 0 "❯ hello${NBSP}world")
  [ "$out" = pending ] || fail "a no-break space inside typed text must stay pending, got '$out'"
  out=$(classify 0 "❯${NBSP}hello")
  [ "$out" = pending ] || fail "text right after a no-break space must stay pending, got '$out'"
  out=$(classify 1 "deploy${NBSP}staging")
  [ "$out" = pending ] || fail "bordered text containing a no-break space must stay pending, got '$out'"
  # Trailing padding after real text is trimmed, but the text still wins.
  out=$(classify 0 "❯ hello$NBSP")
  [ "$out" = pending ] || fail "text with trailing padding must stay pending, got '$out'"
  pass "fm_composer_classify_content: padding inside typed text is content, not padding"
}

test_trim_ws_is_leading_and_trailing_only() {
  local out
  out=$(fm_composer_trim_ws "${NBSP} ${NBSP}text${NBSP}here${NBSP} ${NBSP}")
  [ "$out" = "text${NBSP}here" ] \
    || fail "fm_composer_trim_ws must strip mixed edge padding and keep interior padding, got '$out'"
  out=$(fm_composer_trim_ws "$NBSP")
  [ -z "$out" ] || fail "fm_composer_trim_ws on padding alone must yield the empty string, got '$out'"
  # The multibyte agent glyph must survive intact - the trim removes whole
  # sequences and must never shave a byte off a legitimate character.
  out=$(fm_composer_trim_ws "$CLAUDE_EMPTY_ROW")
  [ "$out" = '❯' ] || fail "fm_composer_trim_ws must leave '❯' byte-intact, got '$out'"
  pass "fm_composer_trim_ws: strips only leading/trailing padding and never splits a multibyte glyph"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_observed_claude_empty_composer_is_empty
test_ascii_and_bare_glyph_cases_do_not_regress
test_every_included_padding_sequence_reads_empty
test_excluded_sequences_are_not_padding
test_padding_inside_real_text_stays_pending
test_trim_ws_is_leading_and_trailing_only
