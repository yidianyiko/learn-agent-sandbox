#!/usr/bin/env bash
#
# s04 part 2 — a control plane that can be killed
#
# Starts sandboxd, creates two sandboxes, kills the control plane with
# SIGKILL, shows the machines are untouched, then starts a new control
# plane and watches it adopt them.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${TMPDIR:-/tmp}/s04-state-$$"
ADDR="127.0.0.1:8080"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'
else B=''; G=''; Y=''; D=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$HERE/../assets/firecracker" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }
command -v go >/dev/null || { echo "go not found — see ../scripts/check-env.sh"; exit 1; }

BIN="$STATE/sandboxd"
mkdir -p "$STATE"
cleanup() {
  [ -n "${CP:-}" ] && kill -9 "$CP" 2>/dev/null
  for f in "$STATE"/*.json; do
    [ -e "$f" ] || continue
    p=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$f")
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  rm -rf "$STATE"
}
trap cleanup EXIT

go build -o "$BIN" . || exit 1

start_control_plane() { # -> sets CP
  "$BIN" -addr "$ADDR" -state "$STATE" -assets "$HERE/../assets" > "$STATE/cp.log" 2>&1 &
  CP=$!
  # Detach it from job control so bash does not print "Killed" when we
  # shoot it later — the point of that step is the VMs, not the notice.
  disown "$CP" 2>/dev/null || true
  for _ in $(seq 1 200); do
    curl -sf "http://$ADDR/sandbox" >/dev/null 2>&1 && return 0
    sleep 0.02
  done
  echo "control plane never came up"; cat "$STATE/cp.log"; exit 1
}

pids_from_state() { sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$STATE"/*.json 2>/dev/null | paste -sd,; }

# ── 1 ─────────────────────────────────────────────────────────────────
printf '%s1 · Start the control plane, create two sandboxes%s\n\n' "$B" "$X"
start_control_plane
printf '   control plane pid %s\n' "$CP"
for _ in 1 2; do
  ID=$(curl -sf -X POST "http://$ADDR/sandbox" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p')
  printf '   POST /sandbox -> %s\n' "$ID"
done
printf '\n   GET /sandbox\n'
curl -sf "http://$ADDR/sandbox" | sed 's/^/   /'
printf '\n'

# ── 2 ─────────────────────────────────────────────────────────────────
printf '%s2 · What is on disk%s  %s(the part that survives)%s\n\n' "$B" "$X" "$D" "$X"
for f in "$STATE"/*.json "$STATE"/*.sock; do
  [ -e "$f" ] && printf '   %s\n' "${f##*/}"
done
printf '\n'

# ── 3 ─────────────────────────────────────────────────────────────────
printf '%s3 · Kill the control plane%s\n\n' "$B" "$X"
VMPIDS=$(pids_from_state)
kill -9 "$CP" 2>/dev/null; sleep 0.7
printf '   control plane: %s\n' "$(ps -p "$CP" >/dev/null 2>&1 && echo alive || echo gone)"
printf '   GET /sandbox : %s\n\n' "$(curl -sf --max-time 1 "http://$ADDR/sandbox" >/dev/null 2>&1 && echo answers || echo 'connection refused')"
printf '   the machines:\n'
ps -o pid,ppid,stat,comm -p "$VMPIDS" 2>/dev/null | sed 's/^/   /' || printf '   %sgone%s\n' "$Y" "$X"
printf '\n   %sstill running, reparented to init, and nothing is watching them%s\n\n' "$G" "$X"

# ── 4 ─────────────────────────────────────────────────────────────────
printf '%s4 · Start a new control plane%s\n\n' "$B" "$X"
CP=""
start_control_plane
grep -E 'adopted' "$STATE/cp.log" | sed 's/^/   /'
printf '\n   GET /sandbox\n'
curl -sf "http://$ADDR/sandbox" | sed 's/^/   /'
printf '\n'

# ── 5 ─────────────────────────────────────────────────────────────────
printf '%s5 · Kill one machine behind its back, then ask again%s\n\n' "$B" "$X"
FIRST=$(echo "$VMPIDS" | cut -d, -f1)
kill -9 "$FIRST" 2>/dev/null; sleep 0.5
printf '   killed pid %s directly, without telling the control plane\n\n' "$FIRST"
curl -sf "http://$ADDR/sandbox" | sed 's/^/   /'
printf '\n'
grep -E 'reconcile' "$STATE/cp.log" | tail -2 | sed 's/^/   /'

cat <<SUMMARY

${B}What this means${X}
   The control plane holds no truth of its own. Every answer it gives
   came from looking: a directory of files, and /proc to check each one
   is still the process it claims.

   That is why it can be killed and replaced mid-flight, and why a
   machine that dies behind its back is noticed on the next question
   rather than never.

   ${D}A registry that reads the world beats a registry that remembers it.${X}

SUMMARY
