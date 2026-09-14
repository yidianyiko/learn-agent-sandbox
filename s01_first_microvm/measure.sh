#!/usr/bin/env bash
#
# s01 — where does the boot time actually go?
#
# Boots twice without a terminal attached and reports the breakdown:
#
#   1. the full Ubuntu rootfs, which is what boot.sh gives you
#   2. a 2 MB BusyBox initramfs, which is roughly the floor
#
# The gap between them is your userland, not your hypervisor.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
FC="$ASSETS/firecracker"
KERNEL="$ASSETS/vmlinux-6.1.186"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; X=$'\033[0m'
else B=''; D=''; R=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$FC" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }

# Boot once, return "wall_ms kernel_to_init_s log_path".
boot_once() { # boot_source_json  ready_pattern  extra_api
  local sock log pid t0 t1 matched
  sock="${TMPDIR:-/tmp}/fc-m-$$.sock"; log="${TMPDIR:-/tmp}/fc-m-$$.log"
  rm -f "$sock" "$log"
  "$FC" --api-sock "$sock" > "$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 400); do [ -S "$sock" ] && break; sleep 0.005; done

  api() { curl -s --unix-socket "$sock" -X PUT "http://localhost$1" \
                -H 'Content-Type: application/json' -d "$2" -o /dev/null; }
  api /boot-source "$1"
  [ -n "$3" ] && api /drives/rootfs "$3"
  api /machine-config '{"vcpu_count":1,"mem_size_mib":256}'

  t0=$(date +%s%N)
  api /actions '{"action_type":"InstanceStart"}'

  # Wait for the guest to print the line that means "I am up". Record
  # whether it ever did: without this flag a guest that never boots still
  # falls out of the loop after ~8 s and we would report that as its boot
  # time — a plausible-looking number that is entirely wrong, which is the
  # worst thing a measurement script can produce.
  matched=0
  for _ in $(seq 1 4000); do
    if grep -qE "$2" "$log" 2>/dev/null; then matched=1; break; fi
    sleep 0.002
  done
  t1=$(date +%s%N)
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  rm -f "$sock"          # the log is handed back to the caller; the socket is not

  if [ "$matched" = 0 ]; then
    printf '\n%sThe guest never printed %s, so there is no boot time to report.%s\n' "$R" "$2" "$X" >&2
    printf '%sLast lines of its console:%s\n' "$D" "$X" >&2
    tail -6 "$log" >&2
    rm -f "$log"
    exit 1
  fi

  # These are set as globals rather than returned, because a shell function
  # can only return a status. The caller reads them immediately.
  WALL_MS=$(( (t1 - t0) / 1000000 ))
  # An empty result here means the guest kernel did not log that line —
  # print "n/a" rather than a blank column, which reads like a bug.
  TO_INIT=$(grep -oP '^\[\s*\K[0-9.]+(?=\].*(Run /sbin/init|Run /init))' "$log" | head -1)
  MOUNT_AT=$(grep -oP '^\[\s*\K[0-9.]+(?=\].*VFS: Mounted root)' "$log" | head -1)
  VIRTIO_AT=$(grep -oP '^\[\s*\K[0-9.]+(?=\].*virtio_blk virtio0:.*queues)' "$log" | head -1)
  TO_INIT=${TO_INIT:-n/a}; MOUNT_AT=${MOUNT_AT:-n/a}; VIRTIO_AT=${VIRTIO_AT:-n/a}
  LOG_PATH="$log"
}

printf '%sMeasuring. Each run boots a real VM, so this takes a few seconds.%s\n\n' "$D" "$X"

boot_once "{\"kernel_image_path\":\"$KERNEL\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}" \
          'root@ubuntu-fc-uvm' \
          "{\"drive_id\":\"rootfs\",\"path_on_host\":\"$ASSETS/ubuntu-24.04.squashfs\",\"is_root_device\":true,\"is_read_only\":true}"
U_WALL=$WALL_MS; U_INIT=$TO_INIT; U_MOUNT=$MOUNT_AT; U_VIRTIO=$VIRTIO_AT
rm -f "$LOG_PATH"

boot_once "{\"kernel_image_path\":\"$KERNEL\",\"initrd_path\":\"$ASSETS/initramfs.cpio\",\"boot_args\":\"console=ttyS0 reboot=k panic=1\"}" \
          'Welcome to fcinitrd' ''
I_WALL=$WALL_MS; I_INIT=$TO_INIT
rm -f "$LOG_PATH"

cat <<TABLE

${B}Ubuntu 24.04 on squashfs${X}   ${D}(what boot.sh runs)${X}
  virtio-blk probed          ${U_VIRTIO} s
  root filesystem mounted    ${U_MOUNT} s   ${D}<- squashfs decompression lives here${X}
  kernel hands off to init   ${U_INIT} s
  ${B}wall clock to a shell      ${U_WALL} ms${X}

${B}BusyBox initramfs, 2 MB${X}     ${D}(roughly the floor)${X}
  kernel hands off to init   ${I_INIT} s
  ${B}wall clock to a shell      ${I_WALL} ms${X}

${B}What that means${X}
  Most of the difference is userland. systemd bringing up a full Ubuntu
  costs far more than the hypervisor ever does. The VM itself is cheap;
  the operating system on top of it is not.

  Firecracker's paper reports ~125 ms, measured on bare metal with a
  trimmed kernel and a minimal init. You will not see that here, and the
  honest reason matters more than the number:

    - this is a full-featured CI kernel, not a stripped one
    - squashfs has to decompress as it mounts
    - if you are on WSL2 or any nested setup, every VM exit pays twice

  ${D}Do not trust in-guest timers under nested virtualisation either — the
  BusyBox initramfs cheerfully reports a boot time of several hundred
  seconds, because its clock reference is wrong.${X}

  You can shave this down. You cannot shave it to zero.
  ${B}s03 stops trying, and restores from a snapshot instead.${X}

TABLE
