#!/usr/bin/env bash
#
# s04 part 1 — what happens to a microVM when its supervisor dies
#
# Starts two VMs from a parent process, kills the parent the rudest way
# available (SIGKILL, no cleanup, no chance to react), and then asks the
# two questions that decide how an orchestrator must be built:
#
#   are the machines still running?
#   can anyone still control them?
#
# Requires: assets fetched, /dev/kvm. No root.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
FC="$ASSETS/firecracker"
WORK="${TMPDIR:-/tmp}/s04-orphans-$$"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'
else B=''; G=''; Y=''; D=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$FC" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }

mkdir -p "$WORK"
cleanup() {
  [ -f "$WORK/pids" ] && xargs -r kill -9 < "$WORK/pids" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# The "supervisor": a process that starts two microVMs and then sits
# there, exactly as a real orchestrator would while serving its API.
cat > "$WORK/supervisor.sh" <<SUPERVISOR
#!/usr/bin/env bash
api() { curl -s --unix-socket "\$1" -X PUT "http://localhost\$2" \\
             -H 'Content-Type: application/json' -d "\$3" -o /dev/null; }
for i in 1 2; do
  S="$WORK/vm\$i.sock"
  "$FC" --api-sock "\$S" > "$WORK/vm\$i.log" 2>&1 &
  echo \$! >> "$WORK/pids"
  for _ in \$(seq 1 400); do [ -S "\$S" ] && break; sleep 0.005; done
  api "\$S" /boot-source '{"kernel_image_path":"$ASSETS/vmlinux-6.1.186","initrd_path":"$ASSETS/initramfs.cpio","boot_args":"console=ttyS0 reboot=k panic=1"}'
  api "\$S" /machine-config '{"vcpu_count":1,"mem_size_mib":128}'
  api "\$S" /actions '{"action_type":"InstanceStart"}'
done
sleep 300
SUPERVISOR
chmod +x "$WORK/supervisor.sh"

printf '%s1 · Two microVMs under a supervisor%s\n\n' "$B" "$X"
"$WORK/supervisor.sh" &
SUP=$!
for _ in $(seq 1 1000); do
  [ -f "$WORK/pids" ] && [ "$(wc -l < "$WORK/pids")" -eq 2 ] && \
    grep -q 'Welcome to fcinitrd' "$WORK/vm2.log" 2>/dev/null && break
  sleep 0.01
done
PIDLIST=$(paste -sd, "$WORK/pids")

printf '   supervisor pid %s\n' "$SUP"
ps -o pid,ppid,stat,comm -p "$PIDLIST" 2>/dev/null | sed 's/^/   /'
printf '\n   %sPPID is the supervisor. It owns them, in the ordinary Unix sense.%s\n\n' "$D" "$X"

printf '%s2 · Kill the supervisor — SIGKILL, no cleanup, no warning%s\n\n' "$B" "$X"
kill -9 "$SUP" 2>/dev/null
wait "$SUP" 2>/dev/null
sleep 1
printf '   supervisor: %s\n\n' "$(ps -p "$SUP" >/dev/null 2>&1 && echo "still there" || echo "gone")"

printf '%s3 · The machines%s\n\n' "$B" "$X"
if ps -o pid,ppid,stat,comm -p "$PIDLIST" >/dev/null 2>&1; then
  ps -o pid,ppid,stat,comm -p "$PIDLIST" 2>/dev/null | sed 's/^/   /'
  printf '\n   %sPPID is now 1. Both were adopted by init and neither noticed.%s\n\n' "$G" "$X"
else
  printf '   %sthey died with their parent%s\n\n' "$Y" "$X"
fi

printf '%s4 · Can anyone still control them?%s\n\n' "$B" "$X"
for i in 1 2; do
  CODE=$(curl -s --unix-socket "$WORK/vm$i.sock" -X GET http://localhost/ \
              -o /dev/null -w '%{http_code}' 2>/dev/null)
  printf '   vm%s  GET /  -> HTTP %s\n' "$i" "${CODE:-no answer}"
done

cat <<SUMMARY

${B}What this means${X}
   A microVM is a process. s02's name pays off here: KVM is
   ${D}Kernel${X}-based, so a virtual machine is scheduled, owned and
   reparented like anything else on the box.

   The supervisor was ${B}bookkeeping, not plumbing${X}. Nothing flowed
   through it, so losing it cost nothing that was running.

   ${Y}And that is also the problem.${X} Those two machines are still
   holding memory and still answering their sockets, and the table that
   knew their names died with the supervisor. They are orphans.

   An orchestrator cannot keep the truth in its own memory. It has to
   write it down somewhere that survives, and be able to walk back in
   and recognise what it finds.

   ${D}That is what part 2 builds.${X}

SUMMARY
