#!/usr/bin/env bash
#
# fetch-assets.sh — download the pinned Firecracker binary, guest kernel
# and root filesystem that every chapter from s01 onward uses.
#
# WHY EVERY VERSION BELOW IS HARD-CODED
# -------------------------------------
# Firecracker's own getting-started guide discovers assets at run time: it
# lists the CI bucket and takes the newest entry, by design, because their
# CI should test the newest thing.
#
# A tutorial must do the opposite. If the kernel moves under the reader,
# the boot log in the chapter stops matching what they see, and a tutorial
# whose output does not match its prose is worse than no tutorial. So we
# resolved "latest" exactly once, on 2026-09-14, and froze the answer here
# along with the checksums.
#
# Bumping these is a deliberate act: change the versions, re-run every
# chapter, update the numbers in the prose, then commit.
#
# No sudo required. No mkfs, no unsquashfs — the guest kernels are built
# with CONFIG_SQUASHFS=y, so the rootfs mounts read-only exactly as shipped.
#
# Usage:  ./scripts/fetch-assets.sh
set -euo pipefail

FC_VERSION="v1.17.0"
CI_ARTIFACTS="firecracker-ci/20260909-a8e1c3830545-0"
KERNEL="vmlinux-6.1.186"
ROOTFS="ubuntu-24.04.squashfs"
INITRAMFS="initramfs.cpio"

S3="https://s3.amazonaws.com/spec.ccfc.min"
GH="https://github.com/firecracker-microvm/firecracker/releases/download"

# sha256, resolved 2026-09-14. The Firecracker one matches the checksum
# published alongside the release; the S3 artifacts ship no checksum, so
# these are ours and are what makes the pin meaningful.
SHA_FC_TGZ="06094a1108ae9e82aa4c23a775aa92758f53f1175d422270d9d6162cb9ade558"
SHA_KERNEL="51565cd5d8bc6d7f3c856acdc8028ad1ef9996d581ac25f47a03429608c4f6ed"
SHA_ROOTFS="9e6809adafdbc297a46c96eeab2c03599420be4e81f1de08b53f427cead8eabf"
SHA_INITRAMFS="7a0bfb917d732dd43b241ebd0e1c3a432077d91c772818369130705b0c9c9229"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$REPO_ROOT/assets"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else
  G=''; Y=''; R=''; B=''; D=''; X=''
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  printf '%sThis script pins x86_64 assets; you are on %s.%s\n' "$R" "$ARCH" "$X"
  echo "Firecracker supports aarch64 too — swap the ARCH in the S3 paths and"
  echo "re-pin the checksums, since they differ per architecture."
  exit 1
fi

mkdir -p "$ASSETS"
cd "$ASSETS"

# Download only if missing or corrupt, then verify. A wrong checksum is a
# hard failure: silently continuing with different bytes is the exact
# failure mode the pinning exists to prevent.
fetch() { # name url expected_sha
  local name="$1" url="$2" want="$3" have=""
  if [ -f "$name" ]; then
    have="$(sha256sum "$name" | cut -d' ' -f1)"
    if [ "$have" = "$want" ]; then
      printf '  %s✔%s %-24s cached\n' "$G" "$X" "$name"
      return 0
    fi
    printf '  %s!%s %-24s checksum mismatch, re-downloading\n' "$Y" "$X" "$name"
    rm -f "$name"
  fi
  printf '  %s…%s %-24s downloading\n' "$D" "$X" "$name"
  curl -fSL --progress-bar -o "$name" "$url"
  have="$(sha256sum "$name" | cut -d' ' -f1)"
  if [ "$have" != "$want" ]; then
    printf '  %s✘%s %s checksum mismatch\n      expected %s\n      got      %s\n' \
      "$R" "$X" "$name" "$want" "$have"
    rm -f "$name"
    exit 1
  fi
  printf '  %s✔%s %-24s verified\n' "$G" "$X" "$name"
}

printf '%sFetching pinned assets into %s%s\n\n' "$B" "$ASSETS" "$X"

printf '%sFirecracker %s%s\n' "$B" "$FC_VERSION" "$X"
fetch "firecracker-${FC_VERSION}.tgz" \
      "${GH}/${FC_VERSION}/firecracker-${FC_VERSION}-x86_64.tgz" \
      "$SHA_FC_TGZ"

# Always extract from the pinned tarball. An earlier version of this script
# skipped extraction whenever a file named `firecracker` already existed,
# which meant bumping FC_VERSION downloaded and verified the new tarball and
# then left the old binary in place — every chapter would quietly run the
# wrong VMM while the summary printed a tick beside it. The checksum
# protects the tarball; nothing was protecting what came out of it.
rm -rf "release-${FC_VERSION}-x86_64"
tar xzf "firecracker-${FC_VERSION}.tgz"
# The tarball also carries jailer, the snapshot tools and the seccomp
# filter. We only need the VMM itself; the rest is left in place for
# anyone curious enough to look.
cp "release-${FC_VERSION}-x86_64/firecracker-${FC_VERSION}-x86_64" firecracker
chmod +x firecracker

# And confirm the binary we just installed is the one we pinned.
FC_REPORTED="$(./firecracker --version 2>&1 | head -1)"
case "$FC_REPORTED" in
  *"$FC_VERSION"*) ;;
  *) printf '  %s✘%s firecracker reports "%s", expected %s\n' "$R" "$X" "$FC_REPORTED" "$FC_VERSION"
     exit 1 ;;
esac
printf '  %s✔%s %-24s %s\n\n' "$G" "$X" "firecracker" "$FC_REPORTED"

printf '%sGuest kernel and filesystems%s\n' "$B" "$X"
fetch "$KERNEL"    "${S3}/${CI_ARTIFACTS}/x86_64/${KERNEL}"    "$SHA_KERNEL"
fetch "$ROOTFS"    "${S3}/${CI_ARTIFACTS}/x86_64/${ROOTFS}"    "$SHA_ROOTFS"
fetch "$INITRAMFS" "${S3}/${CI_ARTIFACTS}/x86_64/${INITRAMFS}" "$SHA_INITRAMFS"

cat <<SUMMARY

${B}Ready.${X}  ${D}(assets/ is gitignored — these are downloads, not source)${X}

  firecracker          the VMM, statically linked, no dependencies
  ${KERNEL}      guest kernel, uncompressed ELF
  ${ROOTFS}   Ubuntu rootfs, mounted read-only as shipped
  ${INITRAMFS}       2 MB BusyBox initramfs, for the boot-time comparison

Next: cd s01_first_microvm && ./boot.sh
SUMMARY
