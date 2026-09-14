#!/usr/bin/env bash
#
# s01 — boot a microVM by hand, and sit inside it
#
# Firecracker is configured over a REST API on a unix socket, not by
# command-line flags. So this script does two things at once:
#
#   - runs firecracker in the FOREGROUND, so the guest's serial console
#     is attached to your terminal and you can actually type into the VM
#   - drives its API from a background subshell, so you can read the four
#     calls that turn an idle process into a running machine
#
# Requires: assets fetched (../scripts/fetch-assets.sh) and /dev/kvm.
# Leave the VM by typing `reboot` at the guest prompt.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
KERNEL="$ASSETS/vmlinux-6.1.186"
ROOTFS="$ASSETS/ubuntu-24.04.squashfs"
FC="$ASSETS/firecracker"
SOCK="${TMPDIR:-/tmp}/fc-s01-$$.sock"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; X=$'\033[0m'
else B=''; D=''; R=''; X=''; fi

die() { printf '%s%s%s\n' "$R" "$1" "$X" >&2; exit 1; }

for f in "$FC" "$KERNEL" "$ROOTFS"; do
  [ -f "$f" ] || die "missing $(basename "$f") — run ../scripts/fetch-assets.sh first"
done
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "cannot access /dev/kvm — run ../scripts/check-env.sh"

cleanup() { rm -f "$SOCK"; }
trap cleanup EXIT

# --- the API driver -------------------------------------------------------
# Runs in the background, waits for firecracker to create its socket, then
# issues the four calls. Everything it prints is prefixed so you can tell
# it apart from the guest's own output.
(
  for _ in $(seq 1 400); do [ -S "$SOCK" ] && break; sleep 0.005; done
  [ -S "$SOCK" ] || { echo "api: socket never appeared"; exit 1; }

  api() { # METHOD PATH JSON
    local code
    code=$(curl -s --unix-socket "$SOCK" -X "$1" "http://localhost$2" \
             -H 'Content-Type: application/json' -d "$3" -o /dev/null -w '%{http_code}')
    printf '%sapi: %-4s %-22s -> HTTP %s%s\n' "$D" "$1" "$2" "$code" "$X"
  }

  # 1. Where the guest kernel comes from, and what to tell it.
  #
  #    You do NOT need root= or pci=off here. Firecracker appends
  #    `pci=off root=/dev/vda ro` plus a virtio_mmio.device= entry for every
  #    drive you attach. Writing them yourself just duplicates them in the
  #    guest's /proc/cmdline — harmless, but confusing when you go looking.
  api PUT /boot-source "{
    \"kernel_image_path\": \"$KERNEL\",
    \"boot_args\": \"console=ttyS0 reboot=k panic=1\"
  }"

  # 2. The root filesystem. A squashfs, mounted read-only exactly as the
  #    Firecracker CI ships it. The official guide unpacks it and rebuilds
  #    an ext4 with sudo so it can inject an SSH key; we only need a console,
  #    so we skip all of that. The CI kernels are built CONFIG_SQUASHFS=y.
  api PUT /drives/rootfs "{
    \"drive_id\": \"rootfs\",
    \"path_on_host\": \"$ROOTFS\",
    \"is_root_device\": true,
    \"is_read_only\": true
  }"

  # 3. How much machine to give it. Optional — the default is 1 vCPU and
  #    128 MiB — but being explicit is the point of a tutorial.
  api PUT /machine-config '{
    "vcpu_count": 1,
    "mem_size_mib": 256
  }'

  # 4. Go. This is the call that reaches KVM_RUN and puts a physical CPU
  #    into guest mode.
  printf '%sapi: --- starting, guest output follows ---%s\n' "$D" "$X"
  api PUT /actions '{"action_type": "InstanceStart"}'
) &

cat <<BANNER
${B}Booting a microVM.${X}
  kernel   $(basename "$KERNEL")
  rootfs   $(basename "$ROOTFS")  ${D}(read-only)${X}
  api      $SOCK

${D}Log in is automatic. Type \`reboot\` at the guest prompt to shut it down
and return here.${X}

BANNER

# firecracker replaces this shell, so the guest console owns your terminal.
exec "$FC" --api-sock "$SOCK"
