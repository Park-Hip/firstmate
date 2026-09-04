#!/usr/bin/env bash
set -eu
ROOT=$PWD
TMP="$ROOT/.evidence-watcher-self-heal"
trap 'if [ -d "$TMP" ]; then find "$TMP" -name ".fake-tmux-*" ! -name "*.log" -type f -exec sh -c '\''p=$(cat "$1" 2>/dev/null || true); [ -z "$p" ] || kill -TERM "$p" 2>/dev/null || true'\'' _ {} \;; rm -rf "$TMP"; fi' EXIT
rm -rf "$TMP"
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
session= previous=
for arg in "$@"; do
  if [ "$previous" = -s ] || [ "$previous" = -t ]; then session=$arg; fi
  previous=$arg
done
state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
record="$state/.fake-tmux-${session//\//-}"
case "${1:-}" in
  new-session)
    command=${!#}
    python3 - "$command" "$record" <<'PY'
import subprocess, sys
log = open(sys.argv[2] + ".log", "ab", buffering=0)
p = subprocess.Popen(["/bin/bash", "-c", sys.argv[1]], stdin=subprocess.DEVNULL,
                     stdout=log, stderr=log, start_new_session=True)
open(sys.argv[2], "w").write(str(p.pid) + "\n")
PY
    ;;
  has-session)
    [ -s "$record" ] && kill -0 "$(cat "$record")" 2>/dev/null
    ;;
  kill-session)
    [ -s "$record" ] || exit 1
    kill -CONT "$(cat "$record")" 2>/dev/null || true
    kill -TERM "$(cat "$record")" 2>/dev/null || true
    rm -f "$record"
    ;;
  list-windows) printf 'firstmate:fm-task\n' ;;
  display-message) printf 'claude\n' ;;
  capture-pane|list-panes) : ;;
esac
SH
chmod +x "$TMP/fakebin/tmux"

make_home() {
  home="$TMP/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'window=firstmate:fm-task\nkind=ship\n' > "$home/state/task.meta"
  printf '%s\n' "$home"
}
run_guard() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" PATH="$TMP/fakebin:$PATH" \
    FM_GUARD_GRACE=3 FM_SUPERVISOR_TARGET=test:captain \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISION_MODEL=autoarm \
    "$ROOT/bin/fm-guard.sh" 2>&1
}
show_output() {
  if [ -n "$1" ]; then printf '%s\n' "$1"; else printf '[silent]\n'; fi
}

printf 'SCENARIO 1: quiet working fleet with a fresh auto-arm ledger\n'
home=$(make_home fresh-ledger)
touch "$home/state/.claude-autoarm-epoch"
out=$(run_guard "$home")
printf 'guard output: '; show_output "$out"
printf 'tracked watcher launched: %s\n\n' "$([ -e "$home/state/.watch-arm-terminal" ] && echo yes || echo no)"

printf 'SCENARIO 2: stale ledger with work in flight; self-heal succeeds\n'
home=$(make_home stale-ledger)
out=$(run_guard "$home")
printf 'guard output: '; show_output "$out"
printf 'tracked owner record: %s\n' "$(cat "$home/state/.watch-arm-terminal")"
printf 'watcher beacon created: %s\n\n' "$([ -e "$home/state/.last-watcher-beat" ] && echo yes || echo no)"
# Stop the demonstration watcher before moving to the failure scenario.
record=$(find "$home/state" -name '.fake-tmux-*' ! -name '*.log' -type f | head -1)
[ -z "$record" ] || { kill -TERM "$(cat "$record")" 2>/dev/null || true; rm -f "$record"; }

printf 'SCENARIO 3: stale ledger self-heal is obstructed\n'
home=$(make_home blocked-heal)
mkdir -p "$home/state/.claude-autoarm-failure-alarmed/unremovable"
out1=$(run_guard "$home")
out2=$(run_guard "$home")
printf 'first guard output: '; show_output "$out1"
printf 'second guard output (same episode): '; show_output "$out2"
