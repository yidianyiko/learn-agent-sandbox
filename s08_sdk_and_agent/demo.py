#!/usr/bin/env python3
"""s08 — the whole repository, used rather than explained."""

import sys
import time

from sandbox import Sandbox

BOLD, DIM, GREEN, OFF = "\033[1m", "\033[2m", "\033[32m", "\033[0m"
if not sys.stdout.isatty():
    BOLD = DIM = GREEN = OFF = ""


def main() -> int:
    print(f"{BOLD}1 · One sandbox{OFF}\n")
    t0 = time.monotonic()
    with Sandbox() as sbx:
        boot_ms = (time.monotonic() - t0) * 1000
        print(f"   booted in {boot_ms:.0f} ms   {DIM}(id {sbx.id}){OFF}\n")
        for cmd in ("uname -r", "free -m | awk 'NR==2{print $2\" MB\"}'", "nproc"):
            r = sbx.run(cmd)
            print(f"   {DIM}${OFF} {cmd}\n     {r.stdout}")

        print(f"\n{BOLD}2 · Prepare an environment, then freeze it{OFF}\n")
        sbx.run("mkdir -p /work && echo 'installed at " +
                time.strftime('%H:%M:%S') + "' > /work/setup-log")
        r = sbx.run("cat /work/setup-log")
        print(f"   {DIM}prepared:{OFF} {r.stdout}")

        t0 = time.monotonic()
        snap = sbx.snapshot()
        print(f"   snapshot: {snap.size_mib:.0f} MiB of memory in "
              f"{(time.monotonic() - t0) * 1000:.0f} ms\n")

    print(f"{BOLD}3 · Fork it four ways{OFF}\n")
    t0 = time.monotonic()
    children = snap.fork(4)
    print(f"   four machines in {(time.monotonic() - t0) * 1000:.0f} ms total\n")

    try:
        for i, child in enumerate(children, 1):
            shared = child.run("cat /work/setup-log").stdout
            child.run(f"echo 'branch {i}' > /work/mine")
            mine = child.run("cat /work/mine").stdout
            print(f"   fork {i}   shared: {GREEN}{shared}{OFF}   own: {GREEN}{mine}{OFF}")

        print(f"\n   {DIM}every fork remembers the setup, none can see another's work{OFF}")
    finally:
        for child in children:
            child.close()

    print(f"""
{BOLD}What this means{OFF}
   Eight chapters reduced to four methods. The caller writes

       with Sandbox() as sbx: sbx.run("...")

   and does not need to know about KVM ioctls, cpio archives, vsock
   handshakes, tap devices or copy-on-write memory — all of which are
   still happening, unchanged, underneath.

   {DIM}That is the only thing an SDK ever does: decide what you are
   allowed to stop thinking about.{OFF}
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
