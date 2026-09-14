#!/usr/bin/env bash
#
# check-env.sh — how far up this tutorial can your machine go?
#
# Chapter s00 needs only Docker. Everything above it needs hardware
# virtualization (/dev/kvm), which is the single biggest reason a reader
# gets stuck. This script tells you exactly where you stand and what to
# do about it, in about five seconds.
#
# Usage:  ./scripts/check-env.sh
# Exit:   0 = you can start at s00   1 = nothing will run here

set -uo pipefail

# ---------- output helpers ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else
  R=''; G=''; Y=''; B=''; D=''; X=''
fi
ok()   { printf '  %s✔%s %s\n' "$G" "$X" "$1"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$X" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$X" "$1"; }
hint() { printf '      %s→ %s%s\n' "$D" "$1" "$X"; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$X"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- state ----------
HAS_DOCKER=0; HAS_KVM=0; HAS_GO=0; HAS_RUST=0; HAS_PY=0; HAS_CURL=0; HAS_IP=0
HAS_CC=0; HAS_MAKE=0
FIXES=()

printf '%slearn-agent-sandbox — environment check%s\n' "$B" "$X"

# ---------- platform ----------
head_ "Platform"
OS=$(uname -s)
ARCH=$(uname -m)
KERNEL=$(uname -r)
IS_WSL=0
if [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then IS_WSL=1; fi

if [ "$OS" = "Linux" ]; then
  if [ "$IS_WSL" = "1" ]; then ok "Linux on WSL2 ($ARCH, $KERNEL)"
  else ok "Linux ($ARCH, $KERNEL)"; fi
  case "$ARCH" in
    x86_64|aarch64|arm64) ;;
    *) bad "Firecracker supports x86_64 and aarch64 only — $ARCH will not work" ;;
  esac
else
  bad "$OS ($ARCH) — Firecracker requires Linux"
  hint "s00 still works anywhere Docker runs. For s01+, use a Linux host."
  FIXES+=("Run s01+ on a Linux machine or a cloud VM with nested virtualization.")
fi

# ---------- s00: Docker ----------
head_ "Docker  (needed by s00)"
if have docker; then
  if docker info >/dev/null 2>&1; then
    HAS_DOCKER=1
    ok "docker is installed and the daemon is running"
  else
    warn "docker is installed but the daemon is not reachable"
    hint "start it, or add yourself to the docker group and re-login"
    FIXES+=("Start the Docker daemon (e.g. 'sudo systemctl start docker').")
  fi
else
  bad "docker not found"
  FIXES+=("Install Docker: https://docs.docker.com/engine/install/")
fi

# ---------- s01+: KVM ----------
head_ "Hardware virtualization  (needed by s01 and above)"
if [ "$OS" != "Linux" ]; then
  bad "not applicable on $OS"
elif [ -e /dev/kvm ]; then
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    HAS_KVM=1
    ok "/dev/kvm exists and is readable and writable"
  else
    warn "/dev/kvm exists but you cannot access it"
    hint "sudo usermod -aG kvm \"\$USER\"   then log out and back in"
    FIXES+=("Grant yourself access to /dev/kvm: sudo usermod -aG kvm \$USER")
  fi
else
  bad "/dev/kvm does not exist"
  if [ -r /proc/cpuinfo ] && grep -qE '\b(vmx|svm)\b' /proc/cpuinfo 2>/dev/null; then
    hint "your CPU supports virtualization, but KVM is not exposed"
    if [ "$IS_WSL" = "1" ]; then
      hint "on WSL2, add to %USERPROFILE%\\.wslconfig then 'wsl --shutdown':"
      hint "    [wsl2]"
      hint "    nestedVirtualization=true"
      FIXES+=("Enable nestedVirtualization=true in .wslconfig, then 'wsl --shutdown'.")
    else
      hint "check that virtualization is enabled in BIOS/UEFI,"
      hint "or that your cloud instance type allows nested virtualization"
      FIXES+=("Enable virtualization in BIOS/UEFI, or pick a nested-virt-capable instance.")
    fi
  else
    hint "no vmx/svm flag on this CPU — virtualization is unavailable here"
    FIXES+=("Use a machine whose CPU exposes vmx (Intel) or svm (AMD).")
  fi
fi

# nested-virt detail, informational only
for m in kvm_intel kvm_amd; do
  f=/sys/module/$m/parameters/nested
  if [ -r "$f" ]; then
    v=$(cat "$f" 2>/dev/null)
    case "$v" in
      Y|1) ok "nested virtualization enabled ($m)" ;;
      *)   warn "nested virtualization off ($m=$v) — only matters if you run VMs inside this one" ;;
    esac
  fi
done

# ---------- toolchains ----------
head_ "Toolchains"
have curl    && { HAS_CURL=1; ok "curl      $(curl --version 2>/dev/null | head -1 | cut -d' ' -f1-2)"; } \
             || { bad "curl not found  (s01, s03)"; FIXES+=("Install curl."); }
if have cc || have gcc || have clang; then
  HAS_CC=1; ok "cc        $( { cc --version || gcc --version; } 2>/dev/null | head -1 | cut -c1-40)"
else
  warn "no C compiler  (s02)"; FIXES+=("Install a C compiler (e.g. 'sudo apt install build-essential').")
fi
have make    && { HAS_MAKE=1; ok "make      $(make --version 2>/dev/null | head -1 | cut -d' ' -f3)"; } \
             || { warn "make not found  (s02)"; FIXES+=("Install make."); }
have go      && { HAS_GO=1;   ok "go        $(go version 2>/dev/null | cut -d' ' -f3)"; } \
             || { warn "go not found  (s04, s05, s07)"; FIXES+=("Install Go: https://go.dev/dl/"); }
have cargo   && { HAS_RUST=1; ok "rust      $(cargo --version 2>/dev/null | cut -d' ' -f2)"; } \
             || { warn "cargo not found  (s06)"; FIXES+=("Install Rust: https://rustup.rs"); }
have python3 && { HAS_PY=1;   ok "python3   $(python3 --version 2>/dev/null | cut -d' ' -f2)"; } \
             || { warn "python3 not found  (s08)"; FIXES+=("Install Python 3.10+."); }
have ip      && { HAS_IP=1;   ok "iproute2  (ip)"; } \
             || { warn "'ip' not found  (s07)"; FIXES+=("Install iproute2."); }

# ---------- verdict ----------
head_ "Chapter readiness"
row() { # name, ready(0/1), missing-text
  if [ "$2" = "1" ]; then printf '  %s✔%s  %-26s ready\n' "$G" "$X" "$1"
  else printf '  %s—%s  %-26s needs %s\n' "$Y" "$X" "$1" "$3"; fi
}
# Keep this list in step with the chapter table in README.md. It went stale
# once already, when a chapter was inserted and only the prose was updated.
row "s00  shared kernel"      "$HAS_DOCKER" "docker"
row "s01  first microVM"      "$(( HAS_KVM && HAS_CURL ))" "kvm + curl"
row "s02  write a vmm"        "$(( HAS_KVM && HAS_CC && HAS_MAKE ))" "kvm + cc + make"
row "s03  snapshot / restore" "$(( HAS_KVM && HAS_CURL ))" "kvm + curl"
row "s04  orchestrator"       "$(( HAS_KVM && HAS_GO ))"   "kvm + go"
row "s05  fork / parallel"    "$(( HAS_KVM && HAS_GO ))"   "kvm + go"
row "s06  in-VM agent"        "$(( HAS_KVM && HAS_RUST ))" "kvm + rust"
row "s07  networking"         "$(( HAS_KVM && HAS_GO && HAS_IP ))" "kvm + go + iproute2"
row "s08  sdk and agent"      "$(( HAS_KVM && HAS_PY ))"   "kvm + python3"

if [ ${#FIXES[@]} -gt 0 ]; then
  head_ "To go further"
  printf '  %s\n' "${FIXES[@]}" | sort -u | sed 's/^/  /'
fi

echo
if [ "$HAS_KVM" = "1" ] && [ "$HAS_DOCKER" = "1" ]; then
  printf '%sYou can run the whole tutorial.%s Start at s00_shared_kernel/.\n' "$G" "$X"
  exit 0
elif [ "$HAS_DOCKER" = "1" ]; then
  printf '%sStart at s00_shared_kernel/.%s Fix KVM before s01.\n' "$Y" "$X"
  exit 0
elif [ "$HAS_KVM" = "1" ]; then
  printf '%sKVM is ready — you can start at s01_first_microvm/.%s (s00 needs Docker.)\n' "$Y" "$X"
  exit 0
else
  printf '%sNothing will run here yet.%s See "To go further" above.\n' "$R" "$X"
  exit 1
fi
