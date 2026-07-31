#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh executable-path <harness>
#                                        print the absolute worker-runtime executable for a
#                                        verified harness (exit 0). Exit 1 silently when the
#                                        harness is verified but not installed, exit 2 silently
#                                        when the name is not a verified adapter.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  # Keep marker detection before ancestry detection as an explicit precedence rule.
  # Only claude, pi, and grok set verified markers of their own; codex, opencode,
  # and kimi are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when firstmate runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename -- "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

# --- verified worker-runtime executable resolution ---------------------------
# A verified adapter is knowledge, not an inventory of this machine, so a home can
# resolve a harness whose runtime is not installed at all. Two places need that
# answer - the session-start inventory (bin/fm-bootstrap.sh) and the spawn
# preflight (bin/fm-spawn.sh) - and they must ask it the same way or they will
# disagree about whether the home can launch a worker. This is the one owner.
#
# pi-signed resolves as its own literal executable and never as pi, because
# selecting it is an executable-identity choice (.agents/skills/harness-adapters).
# kimi additionally accepts its documented install fallback
# $HOME/.kimi-code/bin/kimi, which its installer does not always put on PATH.

# harness_absolute_path: normalize a resolved command to an absolute path, so a
# launch command that survives a directory change still names the same binary.
harness_absolute_path() {  # <command-path>
  local candidate=$1 dir
  case "$candidate" in
    /*) printf '%s\n' "$candidate"; return 0 ;;
  esac
  dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
  [ -n "$dir" ] || return 1
  printf '%s/%s\n' "$dir" "$(basename "$candidate")"
}

# resolve_executable_path: print the absolute executable for <harness> and exit 0
# when it is installed. Exit 1 (silently) when the harness is verified but its
# runtime is absent, and exit 2 (silently) when the name is not a verified
# adapter, so callers can tell a missing runtime apart from an unverified adapter
# without parsing text.
resolve_executable_path() {  # <harness>
  local harness=$1 candidate fallback
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
    *) return 2 ;;
  esac
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    harness_absolute_path "$candidate" && return 0
  fi
  if [ "$harness" = kimi ]; then
    fallback="${HOME:-}/.kimi-code/bin/kimi"
    if [ -n "${HOME:-}" ] && [ -x "$fallback" ]; then
      printf '%s\n' "$fallback"
      return 0
    fi
  fi
  return 1
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  executable-path) resolve_executable_path "${2:-}"; exit $? ;;
  *) detect_own ;;
esac
