#!/usr/bin/env bash
#
# s00 — Your container is not a sandbox
#
# Four demonstrations that a container and its host run on ONE kernel.
# Everything here is documented, non-destructive behaviour: we only read.
#
# Requires: Docker. No KVM, no root.
# Usage:    ./demo.sh

set -uo pipefail

# Image tags are pinned. An unpinned `alpine` resolves to `alpine:latest`,
# which changes under you — and a tutorial whose output no longer matches
# its prose is worse than no tutorial. Pin everything.
ALPINE="alpine:3.20"
DEBIAN="debian:12-slim"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'
else
  B=''; G=''; Y=''; D=''; X=''
fi
say()  { printf '\n%s%s%s\n' "$B" "$1" "$X"; }
note() { printf '%s%s%s\n' "$D" "$1" "$X"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found — see ../scripts/check-env.sh"; exit 1; }
docker info >/dev/null 2>&1     || { echo "docker daemon unreachable — see ../scripts/check-env.sh"; exit 1; }

printf '%sPulling pinned images...%s\n' "$D" "$X"
for img in "$ALPINE" "$DEBIAN"; do
  docker pull -q "$img" >/dev/null || { echo "could not pull $img — check your network"; exit 1; }
done

# Name the host by its distribution, not by `uname -s`. The whole point of
# demo 1 is to line up three DISTRIBUTIONS against one KERNEL, and a row
# reading "host (Linux)" next to "Alpine Linux 3.20" breaks the comparison.
HOST_DISTRO=""
[ -r /etc/os-release ] && HOST_DISTRO=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)
HOST_DISTRO=${HOST_DISTRO:-$(uname -s)}

# ---------------------------------------------------------------------
say "1 · Three distributions, one kernel"
note "   Alpine ships musl + BusyBox. Debian ships glibc. The host is Ubuntu."
note "   Their userlands share nothing. Watch the kernel line."
echo
printf '   %-26s %s\n' "Alpine Linux 3.20" "$(docker run --rm "$ALPINE" uname -r)"
printf '   %-26s %s\n' "Debian 12" "$(docker run --rm "$DEBIAN" uname -r)"
printf '   %-26s %s%s%s\n' "host ($HOST_DISTRO)" "$G" "$(uname -r)" "$X"
echo
note "   A Linux distribution is userland files plus a kernel."
note "   An image contains NO kernel. Docker swaps the files, not the engine."

# ---------------------------------------------------------------------
say "2 · The container cannot see its own limits"
LIMIT_MB=128
# The cgroup limit lives at a different path on v2 and v1. Reading only the
# v2 path silently reports 0 on a v1 host, which would contradict the prose
# on this very page — so try both.
OUT=$(docker run --rm -m "${LIMIT_MB}m" "$ALPINE" sh -c '
  lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null \
     || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null \
     || echo unknown)
  echo "$(free -m | awk "NR==2{print \$2}")|$lim|$(nproc)"')
SEEN_MB=${OUT%%|*};  REST=${OUT#*|}
CG_BYTES=${REST%%|*}; CG_CPUS=${REST##*|}
echo
printf '   %-34s %s MB\n' "limit we imposed (cgroup)" "$LIMIT_MB"
if [ "$CG_BYTES" = "unknown" ]; then
  printf '   %-34s %s(cgroup path not found on this host)%s\n' "what the cgroup file says" "$D" "$X"
else
  printf '   %-34s %s MB   %s<- enforced%s\n' "what the cgroup file says" "$((CG_BYTES/1024/1024))" "$D" "$X"
fi
printf '   %-34s %s%s MB%s  <- what the app sees\n' "what \`free\` reports" "$Y" "$SEEN_MB" "$X"
printf '   %-34s %s MB\n' "actual host memory" "$(free -m | awk 'NR==2{print $2}')"
printf '   %-34s %s   (host has %s)\n' "CPUs via nproc" "$CG_CPUS" "$(nproc)"
echo
note "   cgroups ENFORCE the limit but do not VIRTUALISE the view."
note "   /proc/meminfo is the host's. This is why JVM/Node/Go runtimes"
note "   historically sized their heaps from host RAM and got OOMKilled."

# ---------------------------------------------------------------------
say "3 · You are reading the host kernel's internals"
C_UP=$(docker run --rm "$ALPINE" cut -d' ' -f1 /proc/uptime)
H_UP=$(cut -d' ' -f1 /proc/uptime)
C_MOD=$(docker run --rm "$ALPINE" ls /sys/module | wc -l)
H_MOD=$(ls /sys/module | wc -l)
echo
printf '   %-34s %s s  %s<- it started milliseconds ago%s\n' "uptime reported inside container" "$C_UP" "$Y" "$X"
printf '   %-34s %s s\n' "uptime of the host" "$H_UP"
printf '   %-34s %s\n' "kernel modules seen in container" "$C_MOD"
printf '   %-34s %s\n' "kernel modules loaded on host" "$H_MOD"
echo
note "   A container born one second ago claims days of uptime, and can"
note "   enumerate the host's loaded kernel modules. It is not looking at"
note "   its own kernel. There is no 'its own kernel'."

# ---------------------------------------------------------------------
say "4 · How thin the wall is when you misconfigure it"
N_PLAIN=$(docker run --rm "$ALPINE" ls /dev | wc -l)
N_PRIV=$(docker run --rm --privileged "$ALPINE" ls /dev | wc -l)
N_HOST=$(ls /dev | wc -l)
BLK=$(docker run --rm --privileged "$ALPINE" sh -c 'ls /dev | grep -E "^(sd|nvme|vd)" | head -4 | tr "\n" " "')
echo
printf '   %-34s %s\n' "device nodes, normal container" "$N_PLAIN"
printf '   %-34s %s%s%s\n' "device nodes, --privileged" "$Y" "$N_PRIV" "$X"
printf '   %-34s %s\n' "device nodes on the host" "$N_HOST"
printf '   %-34s %s\n' "host block devices now exposed" "${BLK:-none}"
echo
note "   One flag and the host's raw disks are addressable from inside."
note "   We only listed them. Nothing here was mounted or modified."

# ---------------------------------------------------------------------
say "What this means"
cat <<'SUMMARY'
   namespaces changed what the process can SEE.
   cgroups     changed how much it can USE.
   Neither changed WHERE ITS SYSTEM CALLS GO.

   Every open(), mmap() and ioctl() from that container lands in the
   same kernel your host runs — the security boundary is the syscall
   interface, and there are 300+ of them.

   That is an acceptable trade when you wrote the code and reviewed it.
   An agent's code was written seconds ago and reviewed by nobody.

   Next: s01 — start a machine with a kernel of its very own.
SUMMARY
echo
