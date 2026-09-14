#!/usr/bin/env bash
#
# s07 — give the machine a network
#
# Three acts:
#   1. hold a tap device open and watch the kernel talk into an empty wire
#   2. plug a microVM into that wire and watch the other end answer
#   3. NAT the guest out to the internet, and reach a service in it from here
#
# The guest still has no privileges. The HOST needs root for exactly two
# things — creating the tap and writing a NAT rule — and nothing else in
# this repository needs root at all.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$HERE/../assets"
AGENT_DIR="$HERE/../s06_in_vm_agent"
FC="$ASSETS/firecracker"
WORK="${TMPDIR:-/tmp}/s07-net-$$"

TAP="fcnet0"
HOST_IP="172.16.77.1"
GUEST_IP="172.16.77.2"
MASK="255.255.255.0"
SUBNET="172.16.77.0/24"
GUEST_MAC="06:00:AC:10:4D:02"
VPORT=1234

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; Y=$'\033[33m'; D=$'\033[2m'; X=$'\033[0m'
else B=''; Y=''; D=''; X=''; fi

[ -r /dev/kvm ] && [ -w /dev/kvm ] || { echo "cannot access /dev/kvm — see ../scripts/check-env.sh"; exit 1; }
[ -f "$FC" ] && [ -f "$ASSETS/busybox" ] || { echo "assets missing — run ../scripts/fetch-assets.sh"; exit 1; }
command -v cargo >/dev/null || { echo "cargo not found — s07 reuses the s06 agent"; exit 1; }
sudo -n true 2>/dev/null || { echo "this chapter needs sudo for the tap device and one NAT rule"; exit 1; }

WAN=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[ -n "$WAN" ] || { echo "no default route — cannot NAT anywhere"; exit 1; }

mkdir -p "$WORK"
cleanup() {
  [ -n "${FCPID:-}" ] && kill -9 "$FCPID" 2>/dev/null
  [ -n "${WIREPID:-}" ] && kill -9 "$WIREPID" 2>/dev/null
  sudo iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE 2>/dev/null
  sudo iptables -D FORWARD -i "$TAP" -j ACCEPT 2>/dev/null
  sudo iptables -D FORWARD -o "$TAP" -j ACCEPT 2>/dev/null
  sudo ip link del "$TAP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

make -s -C "$HERE" tapwire || exit 1
make -s -C "$AGENT_DIR" all || exit 1
BIN="$AGENT_DIR/target/release"

# ── 1 · a wire with nothing on the end ────────────────────────────────
printf '%s1 · A tap device is a wire whose far end is a file descriptor%s\n\n' "$B" "$X"
sudo ip link del "$TAP" 2>/dev/null
sudo ip tuntap add dev "$TAP" mode tap user "$(id -un)"
sudo ip addr add "$HOST_IP/24" dev "$TAP"
sudo ip link set "$TAP" up
printf '   created %s, gave it %s\n\n' "$TAP" "$HOST_IP"

( sleep 0.8; ping -c2 -W1 "$GUEST_IP" >/dev/null 2>&1 ) &
timeout 6 "$HERE/tapwire" "$TAP" 2>&1 | sed 's/^/   /'
printf '\n'

# ── 2 · plug a machine into it ────────────────────────────────────────
printf '%s2 · Plug a microVM into the same wire%s\n\n' "$B" "$X"
"$BIN/mkinitramfs" "$WORK/initramfs.cpio" \
    "init=$BIN/agent" "bin/busybox=$ASSETS/busybox" >/dev/null

SOCK="$WORK/fc.sock"; VSOCK="$WORK/v.sock"; LOG="$WORK/fc.log"
"$FC" --api-sock "$SOCK" > "$LOG" 2>&1 &
FCPID=$!
disown "$FCPID" 2>/dev/null || true   # so bash does not announce the kill at cleanup
for _ in $(seq 1 400); do [ -S "$SOCK" ] && break; sleep 0.005; done
api() { curl -s --unix-socket "$SOCK" -X PUT "http://localhost$1" \
             -H 'Content-Type: application/json' -d "$2" -o /dev/null -w '%{http_code}'; }

# ip=<client>::<gateway>:<mask>::<device>:off — the kernel configures eth0
# during boot, before any userspace exists to do it.
BOOTARGS="console=ttyS0 reboot=k panic=1 ip=${GUEST_IP}::${HOST_IP}:${MASK}::eth0:off"
api /boot-source "{\"kernel_image_path\":\"$ASSETS/vmlinux-6.1.186\",\"initrd_path\":\"$WORK/initramfs.cpio\",\"boot_args\":\"$BOOTARGS\"}" >/dev/null
api /machine-config '{"vcpu_count":1,"mem_size_mib":256}' >/dev/null
printf '   PUT /network-interfaces/eth0 -> %s   %s(host_dev_name %s)%s\n' \
  "$(api /network-interfaces/eth0 "{\"iface_id\":\"eth0\",\"host_dev_name\":\"$TAP\",\"guest_mac\":\"$GUEST_MAC\"}")" "$D" "$TAP" "$X"
api /vsock "{\"guest_cid\":3,\"uds_path\":\"$VSOCK\"}" >/dev/null
api /actions '{"action_type":"InstanceStart"}' >/dev/null

for _ in $(seq 1 2000); do grep -qa 'listening on vsock' "$LOG" && break; sleep 0.005; done
grep -qa 'listening on vsock' "$LOG" || { echo "   agent never came up"; tail -6 "$LOG"; exit 1; }
printf '   %s\n\n' "$(grep -a 'agent:' "$LOG" | head -1)"

printf '   %s$ ip addr show eth0%s\n' "$D" "$X"
"$BIN/vexec" "$VSOCK" "$VPORT" "ip addr show eth0 | head -4" 2>&1 | sed 's/^/     /'
printf '   %s$ ping -c2 %s   (the host, across the tap)%s\n' "$D" "$HOST_IP" "$X"
"$BIN/vexec" "$VSOCK" "$VPORT" "ping -c2 -W2 $HOST_IP" 2>&1 | sed 's/^/     /'

# ── 3 · NAT it to the world ───────────────────────────────────────────
printf '\n%s3 · NAT the guest out through %s%s\n\n' "$B" "$WAN" "$X"
sudo sysctl -qw net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN" -j MASQUERADE
sudo iptables -A FORWARD -i "$TAP" -j ACCEPT
sudo iptables -A FORWARD -o "$TAP" -j ACCEPT
printf '   %siptables -t nat -A POSTROUTING -s %s -o %s -j MASQUERADE%s\n\n' "$D" "$SUBNET" "$WAN" "$X"

printf '   %s$ echo nameserver 1.1.1.1 > /etc/resolv.conf; wget -qO- http://example.com%s\n' "$D" "$X"
"$BIN/vexec" "$VSOCK" "$VPORT" \
  "mkdir -p /etc; echo nameserver 1.1.1.1 > /etc/resolv.conf; wget -qO- -T8 http://example.com 2>&1 | head -c 220; echo" 2>&1 | sed 's/^/     /'

printf '\n   %s$ ping -c2 1.1.1.1%s\n' "$D" "$X"
"$BIN/vexec" "$VSOCK" "$VPORT" "ping -c2 -W3 1.1.1.1" 2>&1 | tail -4 | sed 's/^/     /'
printf '   %sICMP often does not survive an outer NAT — WSL2 and many clouds drop it\n   while passing TCP happily. A failed ping is not a failed network.%s\n' "$D" "$X"

cat <<SUMMARY

${B}What this means${X}
   The tap device was the whole idea: an interface the kernel treats as
   real, whose far side is a file descriptor. In act 1 this program held
   it and watched the host shout into an empty cable. In act 2
   Firecracker held it instead, and something answered.

   Everything after that is ordinary Linux routing. The guest is a host
   on a /24 that happens to have one neighbour, and ${Y}MASQUERADE${X} is the
   same rule your home router applies to you.

   ${D}Note which side needed privileges. Creating the interface and writing
   a NAT rule are host operations and need root. The machine running
   untrusted code needed none — which is the arrangement you want.${X}

SUMMARY
