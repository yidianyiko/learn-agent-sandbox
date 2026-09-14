#!/usr/bin/env bash
#
# s06 — put a program inside a machine, and talk to it
#
# Builds the agent, packs it into an initramfs beside a static shell,
# boots a microVM with a vsock device, and runs commands in it from here.
#
# Requires: /dev/kvm, cargo, the fetched assets. No root.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
FC="$ASSETS/firecracker"
WORK="${TMPDIR:-/tmp}/s06-agent-$$"
PORT=1234
GUEST_CID=3

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; D=$'\033[2m'; X=$'\033[0m'
else B=''; G=''; D=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$FC" ] && [ -f "$ASSETS/busybox" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }
command -v cargo >/dev/null || { echo "cargo not found — see ../scripts/check-env.sh"; exit 1; }

mkdir -p "$WORK"
cleanup() { [ -n "${FCPID:-}" ] && kill -9 "$FCPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$HERE/target/release"
printf '%s1 · Build the agent%s\n\n' "$B" "$X"
make -s -C "$HERE" all || exit 1
printf '   %-14s %s bytes   %sruns as PID 1 inside the guest%s\n' \
       "agent" "$(stat -c%s "$BIN/agent")" "$D" "$X"
printf '   %-14s %s bytes   %sruns here%s\n\n' \
       "vexec" "$(stat -c%s "$BIN/vexec")" "$D" "$X"

printf '%s2 · Pack it into an initramfs%s  %s(a cpio archive, nothing more)%s\n\n' "$B" "$X" "$D" "$X"
"$BIN/mkinitramfs" "$WORK/initramfs.cpio" \
    "init=$BIN/agent" "bin/busybox=$ASSETS/busybox" | sed 's/^/ /'
printf '\n'

printf '%s3 · Boot it, with a vsock device%s\n\n' "$B" "$X"
SOCK="$WORK/fc.sock"; VSOCK="$WORK/v.sock"; LOG="$WORK/fc.log"
"$FC" --api-sock "$SOCK" > "$LOG" 2>&1 &
FCPID=$!
for _ in $(seq 1 400); do [ -S "$SOCK" ] && break; sleep 0.005; done

api() { curl -s --unix-socket "$SOCK" -X PUT "http://localhost$1" \
             -H 'Content-Type: application/json' -d "$2" -o /dev/null -w '%{http_code}'; }
printf '   PUT /boot-source     -> %s\n' "$(api /boot-source "{\"kernel_image_path\":\"$ASSETS/vmlinux-6.1.186\",\"initrd_path\":\"$WORK/initramfs.cpio\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}")"
printf '   PUT /machine-config  -> %s\n' "$(api /machine-config '{"vcpu_count":1,"mem_size_mib":256}')"
printf '   PUT /vsock           -> %s   %s(guest_cid %s, proxied through %s)%s\n' \
       "$(api /vsock "{\"guest_cid\":$GUEST_CID,\"uds_path\":\"$VSOCK\"}")" "$D" "$GUEST_CID" "$(basename "$VSOCK")" "$X"
printf '   PUT /actions         -> %s\n\n' "$(api /actions '{"action_type":"InstanceStart"}')"

for _ in $(seq 1 2000); do grep -qa 'listening on vsock' "$LOG" && break; sleep 0.005; done
if ! grep -qa 'listening on vsock' "$LOG"; then
  echo "   the agent never announced itself:"; tail -8 "$LOG"; exit 1
fi
printf '   %sguest says: %s%s\n\n' "$G" "$(grep -a 'agent:' "$LOG" | head -1)" "$X"

printf '%s4 · Run commands in it%s\n\n' "$B" "$X"
for cmd in "uname -a" "cat /proc/uptime" "free -m | head -2" "ls /usr/bin | wc -l" "ps | wc -l"; do
  printf '   %s$ %s%s\n' "$D" "$cmd" "$X"
  "$BIN/vexec" "$VSOCK" "$PORT" "$cmd" 2>&1 | sed 's/^/     /'
done

cat <<SUMMARY

${B}What this means${X}
   There is now somebody in there. Every chapter before this one worked
   on machines from outside — start, freeze, fork — and none of it could
   ask a machine to do anything.

   The channel is vsock: addressed by (context id, port), with no
   interface, no address, no routing and no DNS. The guest has no network
   and does not need one.

   The program got in by being an initramfs, which is a cpio archive the
   kernel unpacks into a tmpfs before any filesystem exists. Two files:
   our agent, as /init, and a static shell for it to run things with.

   ${D}s07 gives the machine a network. This chapter is what makes that
   optional rather than mandatory.${X}

SUMMARY
