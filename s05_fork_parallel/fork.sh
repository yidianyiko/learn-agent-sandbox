#!/usr/bin/env bash
#
# s05 part 2 — fork a real microVM, and count what it costs
#
# Boots one Ubuntu, snapshots it, then restores that snapshot N times at
# once. Each restore is an independent machine; all of them read the same
# memory file. The measurement is what the Nth one adds.
#
# Requires: assets fetched, /dev/kvm. No root.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
FC="$ASSETS/firecracker"
WORK="${TMPDIR:-/tmp}/s05-fork-$$"
FORKS="${FORKS:-6}"
MEM_MIB=256

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; D=$'\033[2m'; X=$'\033[0m'
else B=''; G=''; D=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$FC" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }

mkdir -p "$WORK"
PIDS=""
cleanup() { for p in $PIDS; do kill -9 "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

MEM="$WORK/base.mem"; STATE="$WORK/base.state"

api() { curl -s --unix-socket "$1" -X "$2" "http://localhost$3" \
             -H 'Content-Type: application/json' -d "$4" -o /dev/null -w '%{http_code}'; }
wait_for() { for _ in $(seq 1 "$3"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.005; done; return 1; }
avail_mb() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo; }
rss_mb()   { ps -o rss= -p "$1" 2>/dev/null | awk '{s+=$1} END{print int(s/1024)}'; }

# ── 1 · one machine, then a snapshot of it ────────────────────────────
printf '%s1 · Boot one Ubuntu and snapshot it%s\n\n' "$B" "$X"
S="$WORK/base.sock"; L="$WORK/base.log"; mkfifo "$WORK/base.in"
"$FC" --api-sock "$S" < "$WORK/base.in" > "$L" 2>&1 &
BASE=$!; PIDS="$PIDS $BASE"
exec 3> "$WORK/base.in"
for _ in $(seq 1 400); do [ -S "$S" ] && break; sleep 0.005; done

api "$S" PUT /boot-source   "{\"kernel_image_path\":\"$ASSETS/vmlinux-6.1.186\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}" >/dev/null
api "$S" PUT /drives/rootfs "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ASSETS/ubuntu-24.04.squashfs\",\"is_root_device\":true,\"is_read_only\":true}" >/dev/null
api "$S" PUT /machine-config "{\"vcpu_count\":1,\"mem_size_mib\":$MEM_MIB}" >/dev/null
api "$S" PUT /actions '{"action_type":"InstanceStart"}' >/dev/null
wait_for "$L" 'root@ubuntu-fc-uvm' 3000 || { echo "guest never reached a prompt"; tail -5 "$L"; exit 1; }

echo 'echo BASE-IMAGE > /tmp/origin' >&3
sleep 1.2
api "$S" PATCH /vm '{"state":"Paused"}' >/dev/null
api "$S" PUT /snapshot/create "{\"mem_file_path\":\"$MEM\",\"snapshot_path\":\"$STATE\"}" >/dev/null
exec 3>&-; kill "$BASE" 2>/dev/null; wait "$BASE" 2>/dev/null
printf '   snapshot: %s MiB of memory, %s bytes of state\n\n' \
       "$(( $(stat -c%s "$MEM") / 1024 / 1024 ))" "$(stat -c%s "$STATE")"

# ── 2 · restore it N times, measuring as we go ────────────────────────
printf '%s2 · Restore it %s times%s\n\n' "$B" "$FORKS" "$X"
BEFORE=$(avail_mb)
printf '   %s%-4s %-12s %-14s %s%s\n' "$D" "#" "restore" "sum of RSS" "system memory used" "$X"
FPIDS=""
for i in $(seq 1 "$FORKS"); do
  s="$WORK/f$i.sock"; l="$WORK/f$i.log"; mkfifo "$WORK/f$i.in"
  "$FC" --api-sock "$s" < "$WORK/f$i.in" > "$l" 2>&1 &
  p=$!; PIDS="$PIDS $p"; FPIDS="$FPIDS,$p"
  eval "exec $((3+i))> \"$WORK/f$i.in\""
  for _ in $(seq 1 400); do [ -S "$s" ] && break; sleep 0.005; done
  t0=$(date +%s%N)
  api "$s" PUT /snapshot/load "{\"snapshot_path\":\"$STATE\",\"mem_file_path\":\"$MEM\",\"resume_vm\":true}" >/dev/null
  t1=$(date +%s%N)
  sleep 0.4
  printf '   %-4s %-12s %-14s %s\n' "$i" "$(( (t1-t0)/1000000 )) ms" \
         "$(rss_mb "${FPIDS#,}") MB" "$(( BEFORE - $(avail_mb) )) MB"
done

printf '\n   %sif nothing were shared: %s x %s MiB = %s MB%s\n\n' \
       "$D" "$FORKS" "$MEM_MIB" "$(( FORKS * MEM_MIB ))" "$X"

# ── 3 · are they actually separate machines? ──────────────────────────
printf '%s3 · Give each one a different future%s\n\n' "$B" "$X"
for i in $(seq 1 "$FORKS"); do
  eval "printf 'echo fork-%s > /tmp/who\\n' $i >&$((3+i))"
done
sleep 1.5
for i in $(seq 1 "$FORKS"); do
  eval "printf 'cat /tmp/origin /tmp/who\\n' >&$((3+i))"
done
sleep 1.5
for i in $(seq 1 "$FORKS"); do
  printf '   fork %s sees: %s\n' "$i" "$(grep -aoE 'BASE-IMAGE|fork-[0-9]+' "$WORK/f$i.log" | tail -2 | paste -sd' ')"
done

cat <<SUMMARY

${B}What this means${X}
   Every machine remembers ${G}BASE-IMAGE${X} — they share a past, written
   once, before any of them existed. Every machine knows only its own
   ${G}fork-N${X} — they have separate futures from the instant they resumed.

   The memory column is why this is interesting. Firecracker maps the
   snapshot file rather than reading it, so the ${FORKS} machines are looking
   at the same physical pages until one of them writes. Only the
   differences cost anything.

   ${D}A snapshot is not a backup of a machine. It is a fork point.${X}

SUMMARY
