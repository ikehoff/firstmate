#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh reporting and session-start clone refresh bounds.
#
# Bootstrap prints one block or line per actionable problem, optional verbose
# BOOTSTRAP_INFO fact, or completed bootstrap no-action fact and is silent when
# all is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)',
# 'MISSING: tasks-axi (install: ...)', 'MISSING: quota-axi (install: ...)', and
# 'BOOTSTRAP_INFO: ...' lines, so those contracts are pinned verbatim. The cases
# are table-driven over the inputs that vary: whether `treehouse get --help`
# advertises --lease, which (if any) tasks-axi version is on PATH, whether
# tasks-axi update advertises --archive-body, whether its mv help advertises
# multi-ID moves, whether quota-axi is on PATH,
# whether the local backend config opts out of tasks-axi backlog mutations, and
# which no-mistakes version is on PATH.
# Dedicated fleet-sync cases pin the computed bootstrap timeout, explicit
# override, blank-env defaulting, partial-output relay, and pre-launch timeout
# scan.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)
export FM_BACKEND_CMUX_BUNDLE_BIN="$TMP_ROOT/no-bundled-cmux"

# Hermetic runtime-backend detection. These cases pin the backend per-home via
# config/backend; the dev shell's ambient runtime markers ($TMUX inside tmux,
# HERDR_ENV inside herdr, CMUX_* inside a cmux terminal) must not leak into
# fm_backend_name and flip a default-backend case onto a non-tmux backend. Unset
# them once so the suite resolves the tmux reference backend unless a case says
# otherwise - the same hermeticity discipline as pinning PATH via BASE_PATH.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true
# Same discipline for the browser check: a dev shell that points chrome-devtools-axi
# at a browser it does not launch would silence the absent-browser report globally.
unset CHROME_DEVTOOLS_AXI_BROWSER_URL CHROME_DEVTOOLS_AXI_AUTO_CONNECT 2>/dev/null || true

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi
  # Bootstrap now reports a resolved worker runtime whose executable is absent, and
  # the resolution of an unconfigured home follows firstmate's OWN harness - which
  # depends on whichever agent runs the suite. Stub every verified adapter so the
  # "all good, stay silent" cases stay hermetic on any developer's machine; the
  # cases that assert HARNESS_MISSING remove the one stub they are about.
  fm_fake_harness_bins "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  fm_fake_shellcheck "$fakebin"
  fm_fake_browser "$fakebin"
  add_tasks_axi "$fakebin" "0.1.1"
  add_quota_axi "$fakebin"
  printf '%s\n' "$fakebin"
}

add_quota_axi() {
  local fakebin=$1
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

add_tasks_axi() {
  local fakebin=$1 version=$2 archive_body=${3:-yes} multi_id=${4:-yes} archive_line mv_usage
  archive_line=""
  [ "$archive_body" = yes ] && archive_line='  --archive-body'
  mv_usage='usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  [ "$multi_id" = yes ] || mv_usage='usage: tasks-axi mv <id> --to <path-or-dir>'
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
  exit 0
fi
if [ "\${1:-}" = update ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  [ -z '$archive_line' ] || printf '%s\n' '$archive_line'
  exit 0
fi
if [ "\${1:-}" = mv ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' '$mv_usage'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

add_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required for dispatch profile validation tests"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

make_fake_fleet_sync_root() {
  local dir=$1 fake_root
  fake_root="$dir/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] || : > "$FM_FAKE_FLEET_SYNC_STARTED_MARKER"
printf '%s\n' 'alpha: synced'
printf '%s\n' 'beta: skipped: no origin remote'
exec perl -e 'sleep 300'
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"
  printf '%s\n' "$fake_root"
}

add_origin_backed_projects() {
  local home=$1 count=$2 i repo
  mkdir -p "$home/projects"
  i=1
  while [ "$i" -le "$count" ]; do
    repo=$(printf '%s/projects/repo-%02d' "$home" "$i")
    git init -q "$repo"
    git -C "$repo" remote add origin "file://$home/remotes/repo-$i.git"
    i=$((i + 1))
  done
}

add_no_origin_projects() {
  local home=$1 count=$2 i repo
  mkdir -p "$home/projects"
  i=1
  while [ "$i" -le "$count" ]; do
    repo=$(printf '%s/projects/local-%02d' "$home" "$i")
    git init -q "$repo"
    i=$((i + 1))
  done
}

run_bootstrap_timeout_case() {
  local home=$1 fake_root=$2 fakebin=$3 override started_marker git_record wait_for_marker
  override=__unset__
  started_marker=${5:-}
  git_record=${6:-}
  wait_for_marker=${7:-0}
  [ "$#" -lt 4 ] || override=$4
  (
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    sleep() {
      local inc=${1:-1}
      SECONDS=$((SECONDS + inc))
      # Advance fake time quickly, but yield on every tick so the background
      # fleet-sync process can deterministically write its partial output before
      # the simulated timeout kills it, even on a busy full-suite runner.
      command sleep 0.01
    }
    # shellcheck disable=SC2317,SC2329 # Exported and invoked by the bootstrap subprocess.
    git() {
      local tries
      if [ "${FM_FAKE_GIT_WAIT_FOR_FLEET_START:-}" = 1 ] && [ -n "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ]; then
        tries=0
        while [ "$tries" -lt 5 ] && [ ! -e "$FM_FAKE_FLEET_SYNC_STARTED_MARKER" ]; do
          command sleep 0.01
          tries=$((tries + 1))
        done
      fi
      if [ -n "${FM_FAKE_GIT_SYNC_STARTED_RECORD:-}" ] && [ -n "${FM_FAKE_FLEET_SYNC_STARTED_MARKER:-}" ] && [ -e "$FM_FAKE_FLEET_SYNC_STARTED_MARKER" ]; then
        printf '%s\n' "$*" >> "$FM_FAKE_GIT_SYNC_STARTED_RECORD"
      fi
      command git "$@"
    }
    export -f sleep
    export -f git
    if [ "$override" = __unset__ ]; then
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    else
      PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
        FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT="$override" \
        FM_FAKE_FLEET_SYNC_STARTED_MARKER="$started_marker" \
        FM_FAKE_GIT_SYNC_STARTED_RECORD="$git_record" \
        FM_FAKE_GIT_WAIT_FOR_FLEET_START="$wait_for_marker" \
        FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
    fi
  )
}

assert_timeout_report() {
  local out=$1 expected_timeout=$2 timing timeout elapsed
  timing=$(printf '%s\n' "$out" | sed -n 's/^FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=\([0-9][0-9]*\)s elapsed=\([0-9][0-9]*\)s)$/\1 \2/p')
  [ -n "$timing" ] || fail "missing fleet-sync timeout report"
  timeout=${timing%% *}
  elapsed=${timing#* }
  [ "$timeout" -eq "$expected_timeout" ] || fail "expected timeout=${expected_timeout}s, got timeout=${timeout}s"
  [ "$elapsed" -ge "$timeout" ] || fail "expected elapsed >= timeout, got elapsed=${elapsed}s timeout=${timeout}s"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<quota 1/0>^<backend or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks quota backend mode expect notcontains case_dir fakebin out n archive_body multi_id
  n=0
  while IFS='^' read -r label lease tasks quota backend mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    if [ "$backend" != "-" ]; then
      mkdir -p "$case_dir/home/config"
      printf '%s\n' "$backend" > "$case_dir/home/config/backlog-backend"
    fi
    fakebin=$(make_fake_toolchain "$case_dir")
    if [ "$tasks" = "-" ]; then
      rm -f "$fakebin/tasks-axi"
    else
      archive_body=yes
      multi_id=yes
      case "$tasks" in
        *:noarchive)
          archive_body=no
          tasks=${tasks%:noarchive}
          ;;
      esac
      case "$tasks" in
        *:nomulti)
          multi_id=no
          tasks=${tasks%:nomulti}
          ;;
      esac
      add_tasks_axi "$fakebin" "$tasks" "$archive_body" "$multi_id"
    fi
    if [ "$quota" = "0" ]; then
      rm -f "$fakebin/quota-axi"
    fi
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
treehouse --lease support is accepted silently^1^0.1.1^1^manual^empty^^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^1^-^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
compatible tasks-axi is silent by default^1^0.1.1^1^-^empty^^
missing tasks-axi is required by default^1^-^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi is required by default^1^0.1.0^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without archive-body is required by default^1^0.1.2:noarchive^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
tasks-axi without multi-id mv is required by default^1^0.2.2:nomulti^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
missing quota-axi is required by default^1^0.1.1^0^manual^exact^MISSING: quota-axi (install: npm install -g quota-axi)^
manual backlog backend still requires missing tasks-axi^1^-^1^manual^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
manual backlog backend suppresses tasks-axi availability^1^0.1.1^1^manual^empty^^
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi/quota-axi bootstrap contracts"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_tasks_axi "$fakebin" "0.1.1"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      missing)
        [ "$out" = "$missing" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_git_is_required_with_supported_install_instruction() {
  local case_dir fakebin bash_env out expected
  case_dir="$TMP_ROOT/git-required"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  bash_env="$case_dir/no-git.bash"
  cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = git ]; then
    return 1
  fi
  builtin command "$@"
}
git() {
  return 127
}
SH

  out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  expected="MISSING: git (install: brew install git  # or the platform's package manager)"
  [ "$out" = "$expected" ] || fail "missing git should report the supported install instruction, got: $out"
  pass "bootstrap requires git with an install instruction"
}

test_orca_backend_gates_orca_tool_only_when_selected() {
  local case_dir fakebin out missing_orca
  missing_orca="MISSING: orca (install: brew install orca  # or the platform's package manager)"

  case_dir="$TMP_ROOT/orca-backend-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ "$out" = "$missing_orca" ] || fail "backend=orca should require only the Orca-specific missing tool, got: $out"

  case_dir="$TMP_ROOT/orca-backend-not-selected"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: orca" "bootstrap should not require orca unless backend=orca is selected"
  pass "bootstrap: backend=orca gates the Orca CLI without requiring it on the default backend"
}

# Build a fake toolchain with tmux REMOVED and the named backend session CLI(s)
# plus jq added, so a backend that must NOT require tmux can be proven silent
# with tmux absent. Echoes the fakebin dir. The removed tmux is what makes these
# cases catch the old "everything but orca demands tmux" bug: with the buggy
# TOOLS list a herdr/zellij/cmux home would report MISSING: tmux here.
make_fake_toolchain_no_tmux() {  # <case-dir> <extra-cli...>
  local dir=$1 fakebin
  shift
  fakebin=$(make_fake_toolchain "$dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" jq "$@"
  printf '%s\n' "$fakebin"
}

test_session_provider_backends_do_not_require_tmux() {
  local backend cli case_dir fakebin out
  # herdr/zellij/cmux are session providers only: they require their own CLI, jq,
  # and treehouse, never tmux. With all genuine deps present and tmux absent,
  # bootstrap must be silent.
  while IFS='^' read -r backend cli; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-no-tmux"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    fakebin=$(make_fake_toolchain_no_tmux "$case_dir" "$cli")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    [ -z "$out" ] || fail "backend=$backend with tmux absent but its own deps present should be silent, got: $out"
  done <<'ROWS'
herdr^herdr
zellij^zellij
cmux^cmux
ROWS
  pass "bootstrap: session-provider backends require their own CLI + jq + treehouse, never tmux"
}

test_session_provider_backends_gate_own_cli_not_tmux() {
  local backend cli case_dir fakebin out missing
  # With the backend's OWN session CLI absent (and tmux also absent), bootstrap
  # must fail closed on the genuine dep and never substitute a false tmux demand.
  while IFS='^' read -r backend cli; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-missing-cli"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    # Toolchain has jq + treehouse but NOT the session CLI and NOT tmux.
    fakebin=$(make_fake_toolchain_no_tmux "$case_dir")
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    if [ "$backend" = herdr ]; then
      missing="MISSING_MANUAL: herdr (instructions: https://herdr.dev)"
    else
      missing="MISSING: $cli"
    fi
    assert_contains "$out" "$missing" "backend=$backend must fail closed on its own missing session CLI"
    if [ "$backend" = herdr ]; then
      assert_not_contains "$out" "MISSING: herdr (install:" \
        "backend=herdr must not advertise manual guidance as an executable install command"
    fi
    assert_not_contains "$out" "MISSING: tmux" "backend=$backend must not demand tmux when its own CLI is missing"
  done <<'ROWS'
herdr^herdr
zellij^zellij
cmux^cmux
ROWS
  pass "bootstrap: a session-provider backend gates its own CLI, never a false tmux requirement"
}

test_herdr_install_requires_manual_action() {
  local out status
  out=$("$ROOT/bin/fm-bootstrap.sh" install herdr 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "install herdr should fail instead of evaluating its manual-install hint"
  [ "$out" = "error: herdr requires manual installation (instructions: https://herdr.dev)" ] \
    || fail "install herdr should return actionable manual-install guidance, got: $out"
  pass "bootstrap: Herdr manual-install guidance is never executed as a shell command"
}

test_cmux_bundled_cli_satisfies_dependency() {
  local case_dir fakebin bundle out
  case_dir="$TMP_ROOT/cmux-bundled-cli"
  mkdir -p "$case_dir/home/config" "$case_dir/bundle"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' cmux > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain_no_tmux "$case_dir")
  fm_fake_exit0 "$case_dir/bundle" cmux
  bundle="$case_dir/bundle/cmux"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BACKEND_CMUX_BUNDLE_BIN="$bundle" FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "a usable bundled cmux CLI should satisfy bootstrap without a PATH shim, got: $out"
  pass "bootstrap: the bundled cmux CLI satisfies the active backend dependency"
}

test_unknown_backend_reports_invalid_configuration() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/unknown-backend"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' bogus > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "BACKEND_INVALID: bogus (known: tmux herdr zellij orca cmux)" \
    "bootstrap should report an unknown resolved backend"
  assert_not_contains "$out" "MISSING: tmux" "an unknown backend should not silently fall back to tmux dependencies"
  pass "bootstrap: unknown resolved backends fail closed with an actionable diagnostic"
}

# --- resolved worker runtime is actually installed (audit finding G1) --------
# A verified adapter is a knowledge set, not an inventory of this machine, so a
# home can resolve a harness that cannot start. fm-spawn.sh refuses such a spawn,
# but without this check session start reported a clean bill of health for a home
# that could not launch a single worker.

# make_harness_case: a home whose crew (and optionally secondmate) harness is
# pinned, on a full fake toolchain with the named harness stubs REMOVED so they
# resolve as absent regardless of what the developer has installed. Prints the
# fake bin dir.
make_harness_case() {  # <case-dir> <crew> [secondmate] [absent-harness...]
  local case_dir=$1 crew=$2 secondmate=$3 fakebin absent
  shift 3
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' tmux > "$case_dir/home/config/backend"
  printf '%s\n' "$crew" > "$case_dir/home/config/crew-harness"
  [ -z "$secondmate" ] || printf '%s\n' "$secondmate" > "$case_dir/home/config/secondmate-harness"
  fakebin=$(make_fake_toolchain "$case_dir")
  for absent in "$@"; do rm -f "$fakebin/$absent"; done
  printf '%s\n' "$fakebin"
}

run_harness_case() {  # <case-dir> <fakebin>
  PATH="$2:$BASE_PATH" FM_HOME="$1/home" FM_ROOT_OVERRIDE="$1/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh"
}

test_absent_crew_harness_runtime_is_reported() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/harness-crew-absent"
  fakebin=$(make_harness_case "$case_dir" codex '' codex)
  out=$(run_harness_case "$case_dir" "$fakebin")
  assert_contains "$out" \
    "HARNESS_MISSING: codex (role: crewmate; install the codex worker runtime or set config/crew-harness to a verified harness that is installed)" \
    "bootstrap should report a configured crewmate runtime that is not installed"
  assert_not_contains "$out" "MISSING: codex (install:" \
    "an absent worker runtime must not pose as an installable bootstrap tool"

  # Same home, runtime present: the check must add no noise.
  case_dir="$TMP_ROOT/harness-crew-present"
  fakebin=$(make_harness_case "$case_dir" codex '')
  out=$(run_harness_case "$case_dir" "$fakebin")
  [ -z "$out" ] || fail "an installed crewmate runtime should keep bootstrap silent, got: $out"
  pass "bootstrap: a configured crewmate worker runtime that is not installed is reported at session start"
}

test_harness_roles_resolve_independently_and_collapse() {
  local case_dir fakebin out count
  # Crew and secondmate harnesses resolve through separate chains, so an absent
  # runtime on either role is its own actionable line.
  case_dir="$TMP_ROOT/harness-both-absent"
  fakebin=$(make_harness_case "$case_dir" codex grok codex grok)
  out=$(run_harness_case "$case_dir" "$fakebin")
  assert_contains "$out" "HARNESS_MISSING: codex (role: crewmate;" \
    "an absent crewmate runtime should be reported when the secondmate harness differs"
  assert_contains "$out" "HARNESS_MISSING: grok (role: secondmate; install the grok worker runtime or set config/secondmate-harness to a verified harness that is installed)" \
    "an absent secondmate runtime should name its own config file"

  # secondmate-harness absent falls back to the crew harness, so the same missing
  # runtime must be reported once, not twice.
  case_dir="$TMP_ROOT/harness-shared-absent"
  fakebin=$(make_harness_case "$case_dir" codex '' codex)
  out=$(run_harness_case "$case_dir" "$fakebin")
  count=$(printf '%s\n' "$out" | grep -c 'HARNESS_MISSING:' || true)
  [ "$count" -eq 1 ] || fail "one missing runtime shared by both roles should report once, got $count lines: $out"
  pass "bootstrap: crewmate and secondmate runtimes are checked independently and an identical resolution reports once"
}

test_unverified_harness_name_is_not_reported_as_missing() {
  local case_dir fakebin out
  # `command -v` on a name that is not a verified adapter is meaningless. The
  # harness fallback rule and crew-dispatch validation own unverified names, so
  # this check must stay silent rather than invent a missing-runtime claim.
  case_dir="$TMP_ROOT/harness-unverified"
  fakebin=$(make_harness_case "$case_dir" bogus-harness '')
  out=$(run_harness_case "$case_dir" "$fakebin")
  assert_not_contains "$out" "HARNESS_MISSING" \
    "an unverified adapter name must not be reported as a missing runtime"
  pass "bootstrap: an unverified harness name is not misreported as an uninstalled runtime"
}

test_harness_executable_path_is_the_shared_resolver() {
  local case_dir fakebin status out fakehome
  # bin/fm-harness.sh executable-path is the ONE owner both bootstrap and the
  # fm-spawn preflight ask, so its three outcomes are pinned here: installed
  # (absolute path, exit 0), verified but absent (exit 1), unverified (exit 2).
  case_dir="$TMP_ROOT/harness-executable-path"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_harness_bins "$fakebin" claude
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh" executable-path claude)
  [ "$out" = "$fakebin/claude" ] \
    || fail "executable-path should print the absolute resolved runtime, got '$out'"

  status=0
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh" executable-path codex 2>&1) || status=$?
  [ "$status" -eq 1 ] || fail "a verified but uninstalled harness should exit 1, got $status"
  [ -z "$out" ] || fail "a missing runtime should be reported by exit code only, got '$out'"

  status=0
  out=$(PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-harness.sh" executable-path bogus-harness 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "an unverified adapter name should exit 2, got $status"
  [ -z "$out" ] || fail "an unverified adapter name should be reported by exit code only, got '$out'"

  # kimi additionally accepts its documented install fallback, which its installer
  # does not always put on PATH; fm-spawn embeds this exact path in its launch.
  fakehome="$case_dir/kimi-home"
  mkdir -p "$fakehome/.kimi-code/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakehome/.kimi-code/bin/kimi"
  chmod +x "$fakehome/.kimi-code/bin/kimi"
  out=$(PATH="$fakebin:$BASE_PATH" HOME="$fakehome" "$ROOT/bin/fm-harness.sh" executable-path kimi)
  [ "$out" = "$fakehome/.kimi-code/bin/kimi" ] \
    || fail "kimi should resolve through its documented install fallback, got '$out'"
  pass "fm-harness.sh executable-path: one resolver answers installed, verified-but-absent, and unverified"
}

test_absent_or_unpinned_shellcheck_is_reported() {
  local case_dir fakebin out pin install_line
  pin=$("$ROOT/bin/fm-lint.sh" --required-version)
  install_line="MISSING: shellcheck (install: $ROOT/bin/fm-install-shellcheck.sh"

  # Absent: bin/fm-lint.sh exits 127, so the repo's own lint gate cannot run and
  # the first firstmate-repo task would fail mid-pipeline instead of at startup.
  case_dir="$TMP_ROOT/shellcheck-absent"
  fakebin=$(make_harness_case "$case_dir" claude '')
  rm -f "$fakebin/shellcheck"
  out=$(run_harness_case "$case_dir" "$fakebin")
  assert_contains "$out" "$install_line" \
    "bootstrap should report an absent ShellCheck with the repo's pinned installer"
  # The captain is told to run `fm-bootstrap.sh install shellcheck`, which strips the
  # trailing comment and evals the rest, so the command must actually be runnable.
  [ -x "$ROOT/bin/fm-install-shellcheck.sh" ] \
    || fail "the printed ShellCheck install command must name an executable script"

  # Present but off the pin: bin/fm-lint.sh exits 1 rather than 127, so presence
  # alone is not the requirement and must not silence the report.
  case_dir="$TMP_ROOT/shellcheck-unpinned"
  fakebin=$(make_harness_case "$case_dir" claude '')
  fm_fake_shellcheck "$fakebin" "0.9.0"
  out=$(run_harness_case "$case_dir" "$fakebin")
  assert_contains "$out" "$install_line" \
    "bootstrap should report a ShellCheck whose version is not the gate's pin"

  # On the pin: no noise.
  case_dir="$TMP_ROOT/shellcheck-pinned"
  fakebin=$(make_harness_case "$case_dir" claude '')
  fm_fake_shellcheck "$fakebin" "$pin"
  out=$(run_harness_case "$case_dir" "$fakebin")
  [ -z "$out" ] || fail "a ShellCheck on the gate's pin should keep bootstrap silent, got: $out"
  pass "bootstrap: an absent or unpinned ShellCheck is reported at session start"
}

test_shellcheck_pin_has_one_owner() {
  local case_dir fakebin out
  # bin/fm-lint.sh owns the pin. If bootstrap ever restated the version instead of
  # asking, the two would drift silently and the gate would still fail mid-run, so
  # pin the delegation: a ShellCheck reporting exactly what fm-lint.sh asks for is
  # accepted no matter what that value is, and bootstrap installs it with the same
  # checksum-verified script CI uses.
  case_dir="$TMP_ROOT/shellcheck-pin-owner"
  fakebin=$(make_harness_case "$case_dir" claude '')
  fm_fake_shellcheck "$fakebin" "$("$ROOT/bin/fm-lint.sh" --required-version)"
  out=$(run_harness_case "$case_dir" "$fakebin")
  assert_not_contains "$out" "shellcheck" \
    "bootstrap must accept exactly the version bin/fm-lint.sh reports as required"
  grep -q 'fm-install-shellcheck.sh' "$ROOT/.github/workflows/ci.yml" \
    || fail "CI should install ShellCheck with the same script bootstrap recommends"
  pass "bootstrap: the ShellCheck requirement is read from bin/fm-lint.sh, not restated"
}

run_browser_case() {  # <case-dir> <fakebin> [VAR=VALUE...]
  local case_dir=$1 fakebin=$2
  shift 2
  env "$@" PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$ROOT/bin/fm-bootstrap.sh"
}

test_absent_browser_is_reported() {
  local case_dir fakebin out missing
  missing="$TMP_ROOT/browser-nowhere/chrome"

  # chrome-devtools-axi is only the driver: it resolves on PATH while the browser
  # it drives is a separate system install. Without one, every visual or browser
  # task fails, and it fails misleadingly - the tool prints a page: block with
  # refs: 0 before the executable error, which reads like an empty page rather
  # than broken tooling. FM_BROWSER_PATHS_OVERRIDE replaces the probe list AND
  # suppresses the PATH-name probe, so this case is hermetic on a machine that
  # does have Chrome installed.
  case_dir="$TMP_ROOT/browser-absent"
  fakebin=$(make_harness_case "$case_dir" claude '')
  out=$(run_browser_case "$case_dir" "$fakebin" "FM_BROWSER_PATHS_OVERRIDE=$missing")
  assert_contains "$out" "MISSING_MANUAL: google-chrome (instructions: https://www.google.com/chrome/" \
    "bootstrap should report an absent browser, not just an absent chrome-devtools-axi"
  # Installing a system browser needs elevated privileges and the captain's
  # consent, so it must never arrive as something `fm-bootstrap.sh install` evals.
  assert_not_contains "$out" "MISSING: google-chrome (install:" \
    "a system browser must be reported as a manual install, never as an evalable command"
  out=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/home" "$ROOT/bin/fm-bootstrap.sh" install google-chrome 2>&1) && \
    fail "fm-bootstrap.sh install google-chrome should refuse rather than install a browser"
  assert_contains "$out" "requires manual installation" \
    "the install path should name the browser as manual rather than run something"

  # A browser at one of the probed locations: no noise.
  case_dir="$TMP_ROOT/browser-present"
  fakebin=$(make_harness_case "$case_dir" claude '')
  : > "$case_dir/chrome"
  out=$(run_browser_case "$case_dir" "$fakebin" "FM_BROWSER_PATHS_OVERRIDE=$missing:$case_dir/chrome")
  [ -z "$out" ] || fail "a browser at a probed location should keep bootstrap silent, got: $out"

  # The PATH-name probe is the second way a browser is found. This stays silent on
  # a machine with a real Chrome too, so it is a smoke assertion rather than an
  # isolation of that one mechanism.
  case_dir="$TMP_ROOT/browser-on-path"
  fakebin=$(make_harness_case "$case_dir" claude '')
  out=$(run_browser_case "$case_dir" "$fakebin")
  [ -z "$out" ] || fail "a google-chrome on PATH should keep bootstrap silent, got: $out"
  pass "bootstrap: an absent browser is reported at session start as a manual install"
}

test_driver_reaching_a_remote_browser_is_silent() {
  local case_dir fakebin out missing
  missing="$TMP_ROOT/browser-nowhere/chrome"
  # Two chrome-devtools-axi modes need no local executable at all: an explicit
  # endpoint, and attaching to a running browser this machine may not own - a
  # Windows Chrome reached from WSL, for instance. Reporting a missing browser in
  # either mode would be crying wolf at every session start on a working home.
  for mode in "CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222" \
              "CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1"; do
    case_dir="$TMP_ROOT/browser-remote-${mode%%=*}"
    fakebin=$(make_harness_case "$case_dir" claude '')
    out=$(run_browser_case "$case_dir" "$fakebin" "FM_BROWSER_PATHS_OVERRIDE=$missing" "$mode")
    [ -z "$out" ] || fail "$mode should keep the browser check silent, got: $out"
  done
  pass "bootstrap: a driver configured to reach a browser it does not launch is silent"
}

test_json_backends_require_jq_not_tmux() {
  local backend case_dir fakebin bash_env out
  # herdr/zellij/cmux parse their backend's JSON output, so jq is a genuine dep.
  # jq lives in a system BASE_PATH dir on many hosts, so force it missing with a
  # command()/jq() override (the same technique the git-required case uses) to keep
  # the assertion host-independent.
  while IFS='^' read -r backend; do
    [ -n "$backend" ] || continue
    case_dir="$TMP_ROOT/$backend-missing-jq"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$backend" > "$case_dir/home/config/backend"
    # Session CLI present, tmux absent, jq deliberately NOT stubbed and masked below.
    fakebin=$(make_fake_toolchain "$case_dir")
    rm -f "$fakebin/tmux"
    fm_fake_exit0 "$fakebin" "$backend"
    bash_env="$case_dir/no-jq.bash"
    cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
SH
    out=$(PATH="$fakebin:$BASE_PATH" BASH_ENV="$bash_env" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    assert_contains "$out" "MISSING: jq" "backend=$backend must fail closed on missing jq"
    assert_not_contains "$out" "MISSING: tmux" "backend=$backend must not demand tmux when jq is missing"
  done <<'ROWS'
herdr
zellij
cmux
ROWS
  pass "bootstrap: JSON-emitting backends require jq (their genuine dep), never tmux"
}

test_treehouse_lease_check_follows_resolved_backend() {
  local case_dir fakebin out
  # A treehouse that lacks durable --lease support is only a problem for a backend
  # that actually uses treehouse. Orca owns its own worktrees, so an old treehouse
  # must NOT trip MISSING: treehouse under backend=orca...
  case_dir="$TMP_ROOT/orca-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' orca > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain "$case_dir")
  rm -f "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" orca
  # FM_FAKE_TREEHOUSE_LEASE_HELP unset: the fake treehouse advertises NO --lease.
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "backend=orca must not require treehouse (even lease-less) or tmux, got: $out"

  # ...but the same lease-less treehouse IS a problem for a session-provider
  # backend that relies on treehouse for worktrees.
  case_dir="$TMP_ROOT/herdr-old-treehouse"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' herdr > "$case_dir/home/config/backend"
  fakebin=$(make_fake_toolchain_no_tmux "$case_dir" herdr)
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: treehouse" "backend=herdr must still require treehouse with durable lease support"
  assert_not_contains "$out" "MISSING: tmux" "backend=herdr must not demand tmux even when treehouse is too old"
  pass "bootstrap: the treehouse lease check follows the resolved backend's worktree provider"
}

test_fleet_sync_timeout_scales_with_origin_backed_project_count() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-scaled"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  add_no_origin_projects "$home" 3
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin")

  assert_contains "$out" $'FLEET_SYNC: alpha: synced\nFLEET_SYNC: beta: skipped: no origin remote' "bootstrap timeout should relay partial fleet-sync output first"
  assert_timeout_report "$out" 59
  pass "bootstrap computes a fleet-size-aware default timeout and preserves partial fleet-sync output"
}

test_fleet_sync_timeout_floor_preserves_small_fleets() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-small"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 2
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin")

  assert_timeout_report "$out" 20
  pass "bootstrap keeps the quick 20s default for small fleets"
}

test_fleet_sync_timeout_explicit_override_wins() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-override"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" 7)

  assert_timeout_report "$out" 7
  assert_not_contains "$out" "timeout=59s" "explicit override should not be replaced by the computed timeout"
  pass "bootstrap preserves FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT as an explicit override"
}

test_fleet_sync_timeout_empty_override_uses_default() {
  local case_dir home fakebin fake_root out
  case_dir="$TMP_ROOT/fleet-timeout-empty-override"
  home="$case_dir/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 18
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" "")

  assert_timeout_report "$out" 59
  assert_not_contains "$out" "timeout=20s" "blank timeout env should not force the legacy floor on a large fleet"
  pass "bootstrap treats a blank timeout override as unset"
}

test_fleet_sync_timeout_is_computed_before_launch() {
  local case_dir home fakebin fake_root out started_marker git_record
  case_dir="$TMP_ROOT/fleet-timeout-launch-order"
  home="$case_dir/home"
  started_marker="$case_dir/fleet-started"
  git_record="$case_dir/git-after-start"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  add_origin_backed_projects "$home" 3
  fakebin=$(make_fake_toolchain "$case_dir")
  fake_root=$(make_fake_fleet_sync_root "$case_dir")

  out=$(run_bootstrap_timeout_case "$home" "$fake_root" "$fakebin" __unset__ "$started_marker" "$git_record" 1)

  [ ! -s "$git_record" ] || fail "fleet sync launched before timeout scan finished: $(tr '\n' ';' < "$git_record")"
  assert_contains "$out" $'FLEET_SYNC: alpha: synced\nFLEET_SYNC: beta: skipped: no origin remote' "launch-order case should relay partial fleet-sync output before reporting its timeout"
  assert_timeout_report "$out" 20
  pass "bootstrap computes the timeout before launching fleet sync"
}

make_routine_bootstrap_fixture() {
  local case_dir=$1 fakebin root home sm c1
  root="$case_dir/root"
  home="$case_dir/home"
  sm="$case_dir/sm"
  fm_git_identity
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' '{"rules":[{"when":"normal work","use":{"harness":"codex"}}],"default":{"harness":"claude","effort":"low"}}' \
    > "$home/config/crew-dispatch.json"
  git init -q -b main "$root"
  {
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'config/crew-harness'
    printf '%s\n' 'config/crew-dispatch.json'
    printf '%s\n' 'config/startup-memory-budget'
  } > "$root/.gitignore"
  printf '%s\n' 'instructions' > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' 'echo ok' > "$root/bin/fm-spawn.sh"
  printf '%s\n' 'skill' > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$sm" "$c1"
  printf '%s\n' sm > "$sm/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '%s\n' 0 ;;
      *) printf '%s\n' codex ;;
    esac
    ;;
  capture-pane) printf '\n' ;;
  list-windows) printf '%s\n' fm-sm ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s|%s|%s\n' "$root" "$home" "$fakebin"
}

run_routine_bootstrap_fixture() {
  local shell=$1 case_dir=$2 fixture root home fakebin
  fixture=$(make_routine_bootstrap_fixture "$case_dir")
  root=${fixture%%|*}
  fixture=${fixture#*|}
  home=${fixture%%|*}
  fakebin=${fixture#*|}
  PATH="$fakebin:$BASE_PATH" FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    "$shell" "$ROOT/bin/fm-bootstrap.sh"
}

test_routine_bootstrap_confirmations_are_silent() {
  local out
  out=$(run_routine_bootstrap_fixture bash "$TMP_ROOT/routine-silent")
  [ -z "$out" ] || fail "routine bootstrap confirmations should be silent, got: $out"
  pass "bootstrap keeps routine tasks-axi, harness, dispatch, and already-live liveness confirmations silent"
}

test_routine_bootstrap_contract_runs_under_system_bash() {
  local out
  [ -x /bin/bash ] || { pass "bootstrap routine contract skipped without /bin/bash"; return; }
  out=$(run_routine_bootstrap_fixture /bin/bash "$TMP_ROOT/routine-bash")
  [ -z "$out" ] || fail "routine bootstrap contract should be silent under /bin/bash, got: $out"
  pass "bootstrap routine contract runs under system /bin/bash"
}

test_crew_dispatch_active_rules_are_verbose_bootstrap_info() {
  local case_dir fakebin out expect
  case_dir="$TMP_ROOT/dispatch-active"
  mkdir -p "$case_dir/home/config"
  printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
  printf '%s\n' '{"rules":[{"when":"fresh news","use":{"harness":"grok"},"why":"current context"},{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]},{"when":"legacy feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"quota-balanced"}],"default":[{"harness":"pi","model":"anthropic/claude-sonnet-5","effort":"high"},{"harness":"grok","model":"grok-4.5","effort":"high"}]}' > "$case_dir/home/config/crew-dispatch.json"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_real_jq "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "active dispatch profile should be silent by default, got: $out"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")

  expect=$'BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json\nBOOTSTRAP_INFO: crew dispatch rule: fresh news -> grok\nBOOTSTRAP_INFO: crew dispatch rule: big feature -> quota-balanced[claude/claude-sonnet-5/high, codex/gpt-5.5/high]\nBOOTSTRAP_INFO: crew dispatch rule: legacy feature -> quota-balanced[claude, codex]\nBOOTSTRAP_INFO: crew dispatch default: quota-balanced[pi/anthropic/claude-sonnet-5/high, grok/grok-4.5/high]'
  [ "$out" = "$expect" ] || fail "active dispatch verbose info block mismatch"$'\n'"expected: $expect"$'\n'"actual:   $out"
  pass "bootstrap surfaces active crew-dispatch rules only as verbose BOOTSTRAP_INFO"
}

test_crew_dispatch_validation() {
  local label body expect mode case_dir fakebin out n
  n=0
  while IFS='^' read -r label body mode expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/dispatch-$n"
    mkdir -p "$case_dir/home/config"
    printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
    printf '%s\n' "$body" > "$case_dir/home/config/crew-dispatch.json"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_real_jq "$fakebin"
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)" ;;
    esac
  done <<'ROWS'
malformed dispatch config is flagged^{"rules":[^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON
unverified dispatch harness is flagged^{"rules":[{"when":"anything","use":{"harness":"spaceship"}}],"default":{"harness":"codex"}}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship
unsupported codex max effort is flagged^{"rules":[{"when":"big feature","use":{"harness":"codex","model":"gpt-5","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
unsupported grok max effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"max"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:max
unsupported grok xhigh effort is flagged^{"rules":[{"when":"deep current work","use":{"harness":"grok","model":"grok-4","effort":"xhigh"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: grok:xhigh
pi max effort is accepted^{"rules":[{"when":"deep coding","use":{"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":"max"}}]}^empty^
pi-signed max effort is accepted^{"rules":[{"when":"signed coding","use":{"harness":"pi-signed","model":"openai-codex/gpt-5.6-sol","effort":"max"}}]}^empty^
unsupported opencode effort is flagged^{"rules":[{"when":"opencode work","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: opencode:high
kimi model profile is accepted^{"rules":[{"when":"kimi work","use":{"harness":"kimi","model":"kimi-code/k3"}}]}^empty^
unsupported kimi effort is flagged^{"rules":[{"when":"kimi work","use":{"harness":"kimi","model":"kimi-code/k3","effort":"high"}}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: kimi:high
array use with quota-balanced is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude","model":"claude-sonnet-5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}],"select":"quota-balanced"}]}^empty^
array use without select is accepted^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}]}]}^empty^
one-element array use is accepted^{"rules":[{"when":"focused feature","use":[{"harness":"claude"}]}]}^empty^
default array is accepted^{"default":[{"harness":"pi","model":"anthropic/claude-sonnet-5"},{"harness":"grok"}]}^empty^
one-element default array is accepted^{"default":[{"harness":"codex"}]}^empty^
empty array use is flagged^{"rules":[{"when":"big feature","use":[]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each rule needs at least one use profile
array profile without harness is flagged^{"rules":[{"when":"big feature","use":[{"model":"gpt-5.5"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each use profile needs harness
array profile with malformed model is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","model":5}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - use profile model and effort must be non-empty strings when present
unknown select is flagged^{"rules":[{"when":"big feature","use":[{"harness":"claude"},{"harness":"codex"}],"select":"mystery"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - unknown select: mystery
array profile unsupported effort is flagged^{"rules":[{"when":"big feature","use":[{"harness":"codex","effort":"max"}]}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max
empty default array is flagged^{"default":[]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default needs at least one profile
non-object default array entry is flagged^{"default":["codex"]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile must be an object
default array profile without harness is flagged^{"default":[{"model":"gpt-5.5"}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - each default profile needs harness
default array malformed effort is flagged^{"default":[{"harness":"codex","effort":3}]}^exact^CREW_DISPATCH: invalid config/crew-dispatch.json - default profile model and effort must be non-empty strings when present
ROWS
  pass "bootstrap validates crew-dispatch.json and reports malformed or unverified configs"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_git_is_required_with_supported_install_instruction
test_orca_backend_gates_orca_tool_only_when_selected
test_session_provider_backends_do_not_require_tmux
test_session_provider_backends_gate_own_cli_not_tmux
test_herdr_install_requires_manual_action
test_cmux_bundled_cli_satisfies_dependency
test_unknown_backend_reports_invalid_configuration
test_absent_crew_harness_runtime_is_reported
test_harness_roles_resolve_independently_and_collapse
test_unverified_harness_name_is_not_reported_as_missing
test_harness_executable_path_is_the_shared_resolver
test_absent_or_unpinned_shellcheck_is_reported
test_shellcheck_pin_has_one_owner
test_absent_browser_is_reported
test_driver_reaching_a_remote_browser_is_silent
test_json_backends_require_jq_not_tmux
test_treehouse_lease_check_follows_resolved_backend
test_fleet_sync_timeout_scales_with_origin_backed_project_count
test_fleet_sync_timeout_floor_preserves_small_fleets
test_fleet_sync_timeout_explicit_override_wins
test_fleet_sync_timeout_empty_override_uses_default
test_fleet_sync_timeout_is_computed_before_launch
test_routine_bootstrap_confirmations_are_silent
test_routine_bootstrap_contract_runs_under_system_bash
test_crew_dispatch_active_rules_are_verbose_bootstrap_info
test_crew_dispatch_validation
