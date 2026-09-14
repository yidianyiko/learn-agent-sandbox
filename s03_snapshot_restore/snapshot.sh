#!/usr/bin/env bash
#
# s03 — the same two operations, at production scale
#
# tinysnap.c showed the mechanism on a 12-byte guest. This does it to a
# real Ubuntu, through Firecracker's API, and times both sides:
#
#   1. boot Ubuntu from cold, leave a mark inside it, snapshot, stop
#   2. start a FRESH firecracker process and restore into it
#   3. ask the restored guest for the mark, to prove it is the same
#      machine and not a new one that looks like it
#
# Requires: assets fetched, /dev/kvm. No root.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
FC="$ASSETS/firecracker"
WORK="${TMPDIR:-/tmp}/s03-snapshot-$$"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'
else B=''; G=''; Y=''; D=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$FC" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }

mkdir -p "$WORK"
cleanup() { pkill -P $$ -f "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

MEM="$WORK/snapshot.mem"      # the guest's RAM
STATE="$WORK/snapshot.state"  # everything else

# One helper for every call. Prints nothing; the caller decides.
api() { # sock method path json
  curl -s --unix-socket "$1" -X "$2" "http://localhost$3" \
       -H 'Content-Type: application/json' -d "$4" -o /dev/null -w '%{http_code}'
}

# Start a firecracker whose console we can both read and type into. The
# FIFO is what lets us send a command to the guest later.
spawn() { # sock log fifo  -> sets PID and opens fd 3 for writing
  rm -f "$2"; mkfifo "$3"
  "$FC" --api-sock "$1" < "$3" > "$2" 2>&1 &
  PID=$!
  exec 3> "$3"
  local i
  for i in $(seq 1 400); do [ -S "$1" ] && break; sleep 0.005; done
}

wait_for() { # log pattern timeout_units -> 0 ok, 1 timed out
  local i
  for i in $(seq 1 "$3"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.005; done
  return 1
}

# ── 1. cold boot ──────────────────────────────────────────────────────
printf '%s1 · Cold boot%s\n' "$B" "$X"
S1="$WORK/a.sock"; L1="$WORK/a.log"
spawn "$S1" "$L1" "$WORK/a.in"; P1=$PID

T0=$(date +%s%N)
api "$S1" PUT /boot-source  "{\"kernel_image_path\":\"$ASSETS/vmlinux-6.1.186\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}" >/dev/null
api "$S1" PUT /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ASSETS/ubuntu-24.04.squashfs\",\"is_root_device\":true,\"is_read_only\":true}" >/dev/null
api "$S1" PUT /machine-config '{"vcpu_count":1,"mem_size_mib":256}' >/dev/null
api "$S1" PUT /actions '{"action_type":"InstanceStart"}' >/dev/null
wait_for "$L1" 'root@ubuntu-fc-uvm' 3000 || { echo "guest never reached a prompt"; tail -5 "$L1"; exit 1; }
T1=$(date +%s%N)
BOOT_MS=$(( (T1 - T0) / 1000000 ))
printf '   %sUbuntu reached a shell in %s ms%s\n\n' "$D" "$BOOT_MS" "$X"

# ── 2. leave a mark, pause, snapshot ──────────────────────────────────
printf '%s2 · Leave a mark, then snapshot%s\n' "$B" "$X"
echo 'echo I-WAS-HERE-BEFORE-THE-SNAPSHOT > /tmp/marker' >&3
sleep 1.5

printf '   PATCH /vm {"state":"Paused"}      -> HTTP %s\n' "$(api "$S1" PATCH /vm '{"state":"Paused"}')"
T0=$(date +%s%N)
CODE=$(api "$S1" PUT /snapshot/create "{\"mem_file_path\":\"$MEM\",\"snapshot_path\":\"$STATE\"}")
T1=$(date +%s%N)
SNAP_MS=$(( (T1 - T0) / 1000000 ))
printf '   PUT /snapshot/create              -> HTTP %s   %s(%s ms)%s\n' "$CODE" "$D" "$SNAP_MS" "$X"

exec 3>&-; kill $P1 2>/dev/null; wait $P1 2>/dev/null
printf '   %s%-22s %12s bytes   the guest RAM%s\n'  "$D" "$(basename "$MEM")"   "$(stat -c%s "$MEM")"   "$X"
printf '   %s%-22s %12s bytes   everything else%s\n\n' "$D" "$(basename "$STATE")" "$(stat -c%s "$STATE")" "$X"

# ── 3. restore into a brand new process ───────────────────────────────
printf '%s3 · Restore%s  %s(a fresh firecracker — /snapshot/load is pre-boot only)%s\n' "$B" "$X" "$D" "$X"
S2="$WORK/b.sock"; L2="$WORK/b.log"
spawn "$S2" "$L2" "$WORK/b.in"; P2=$PID

T0=$(date +%s%N)
CODE=$(api "$S2" PUT /snapshot/load "{\"snapshot_path\":\"$STATE\",\"mem_file_path\":\"$MEM\",\"resume_vm\":true}")
T1=$(date +%s%N)
REST_MS=$(( (T1 - T0) / 1000000 ))
printf '   PUT /snapshot/load                -> HTTP %s   %s(%s ms)%s\n\n' "$CODE" "$D" "$REST_MS" "$X"

# ── 4. is it the same machine? ────────────────────────────────────────
printf '%s4 · Ask it what it remembers%s\n' "$B" "$X"
printf '\n' >&3; sleep 0.3
echo 'cat /tmp/marker' >&3
if wait_for "$L2" 'I-WAS-HERE-BEFORE-THE-SNAPSHOT' 600; then
  printf '   %sthe guest answered: I-WAS-HERE-BEFORE-THE-SNAPSHOT%s\n' "$G" "$X"
  printf '   %sa file written before the snapshot, read after it, in another process%s\n\n' "$D" "$X"
else
  printf '   %sthe guest did not answer%s\n\n' "$Y" "$X"; tail -5 "$L2"
fi
exec 3>&-; kill $P2 2>/dev/null; wait $P2 2>/dev/null

# ── the two numbers ───────────────────────────────────────────────────
cat <<RESULT
${B}The two numbers${X}
   cold boot to a shell   ${BOOT_MS} ms
   restore from snapshot  ${REST_MS} ms
   ${B}$(( BOOT_MS / (REST_MS > 0 ? REST_MS : 1) ))x faster${X}

   Booting spends its time letting a kernel discover its hardware.
   Restoring does not discover anything — the answers are in the file.

RESULT
