"""sandbox.py — every previous chapter, behind four methods.

    with Sandbox() as sbx:
        print(sbx.run("uname -a").stdout)
        snap = sbx.snapshot()

    for child in snap.fork(3):
        child.run("...")

Nothing here is new. It is s01 (boot), s03 (snapshot and restore),
s05 (fork from one snapshot), s06 (talk to the agent over vsock) and
s07 (give it a network), arranged so that the person using it does not
have to know any of that.

Which is the point of the chapter: an SDK is not a feature. It is a
decision about what the caller is allowed to stop thinking about.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass

HERE = pathlib.Path(__file__).resolve().parent
ASSETS = HERE.parent / "assets"
AGENT_BIN = HERE.parent / "s06_in_vm_agent" / "target" / "release"

VSOCK_PORT = 1234
GUEST_CID = 3


class SandboxError(RuntimeError):
    pass


@dataclass
class Result:
    """What came back from one command."""
    stdout: str
    exit_code: int

    def __str__(self) -> str:
        return self.stdout


class Sandbox:
    """One microVM, from boot to shutdown."""

    def __init__(self, *, memory_mib: int = 256, vcpus: int = 1, boot: bool = True):
        self.id = uuid.uuid4().hex[:12]
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix=f"sbx-{self.id}-"))
        self.api_sock = self.dir / "fc.sock"
        self.vsock = self.dir / "v.sock"
        self.log = self.dir / "fc.log"
        self.memory_mib = memory_mib
        self.vcpus = vcpus
        self._proc: subprocess.Popen | None = None
        if boot:
            self._spawn()
            self._configure()
            self._start()
            self._await_agent()

    # -- lifecycle ----------------------------------------------------

    def _spawn(self) -> None:
        self._proc = subprocess.Popen(
            [str(ASSETS / "firecracker"), "--api-sock", str(self.api_sock)],
            stdout=self.log.open("wb"), stderr=subprocess.STDOUT,
        )
        self._await(lambda: self.api_sock.exists(), "the VMM never created its API socket")

    def _api(self, path: str, body: dict, method: str = "PUT") -> None:
        """Firecracker's API is HTTP over a unix socket (s01). Python's http
        client will not dial one, and the whole protocol we need is four
        lines, so we write them.

        Most endpoints are PUT. /vm is PATCH, because it updates the state
        of something that already exists rather than declaring it."""
        payload = json.dumps(body).encode()
        request = (
            f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n"
            f"Content-Type: application/json\r\nContent-Length: {len(payload)}\r\n"
            f"Connection: close\r\n\r\n"
        ).encode() + payload
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(str(self.api_sock))
            s.sendall(request)
            status = s.recv(64).decode(errors="replace").split("\r\n")[0]
        if " 2" not in status:
            raise SandboxError(f"{method} {path}: {status.strip()}")

    def _initramfs(self) -> pathlib.Path:
        out = self.dir / "initramfs.cpio"
        subprocess.run(
            [str(AGENT_BIN / "mkinitramfs"), str(out),
             f"init={AGENT_BIN / 'agent'}", f"bin/busybox={ASSETS / 'busybox'}"],
            check=True, stdout=subprocess.DEVNULL,
        )
        return out

    def _configure(self) -> None:
        self._api("/boot-source", {
            "kernel_image_path": str(ASSETS / "vmlinux-6.1.186"),
            "initrd_path": str(self._initramfs()),
            "boot_args": "console=ttyS0 reboot=k panic=1",
        })
        self._api("/machine-config", {"vcpu_count": self.vcpus, "mem_size_mib": self.memory_mib})
        self._api("/vsock", {"guest_cid": GUEST_CID, "uds_path": str(self.vsock)})

    def _start(self) -> None:
        self._api("/actions", {"action_type": "InstanceStart"})

    def _await_agent(self) -> None:
        self._await(lambda: "listening on vsock" in self._console(),
                    "the agent never announced itself")

    def _console(self) -> str:
        try:
            return self.log.read_text(errors="replace")
        except OSError:
            return ""

    @staticmethod
    def _await(cond, message: str, timeout: float = 20.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if cond():
                return
            time.sleep(0.005)
        raise SandboxError(message)

    # -- the useful part ----------------------------------------------

    def run(self, command: str, timeout: float = 30.0) -> Result:
        """Run one command inside the machine and wait for it to finish.

        The handshake is s06's: connect to the VMM's unix socket, ask for a
        vsock port, then the stream is wired to whatever accepted inside.
        """
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(str(self.vsock))
            s.sendall(f"CONNECT {VSOCK_PORT}\n".encode())
            ack = b""
            while not ack.endswith(b"\n"):
                chunk = s.recv(1)
                if not chunk:
                    raise SandboxError("the VMM closed the connection — is the agent listening?")
                ack += chunk
            if not ack.startswith(b"OK"):
                raise SandboxError(f"handshake refused: {ack!r}")

            s.sendall(command.encode() + b"\n")
            out = bytearray()
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                out += chunk

        text = out.decode(errors="replace")
        code = 0
        marker = text.rfind("[exit ")
        if marker != -1:
            try:
                code = int(text[marker + 6:text.index("]", marker)])
            except ValueError:
                pass
            text = text[:marker]
        return Result(text.strip("\n"), code)

    def snapshot(self, into: pathlib.Path | None = None) -> "Snapshot":
        """Freeze the machine to two files (s03). The sandbox stays paused."""
        target = pathlib.Path(into or tempfile.mkdtemp(prefix="snap-"))
        target.mkdir(parents=True, exist_ok=True)
        mem, state = target / "mem", target / "state"
        self._api("/vm", {"state": "Paused"}, method="PATCH")
        self._api("/snapshot/create", {"mem_file_path": str(mem), "snapshot_path": str(state)})
        return Snapshot(mem, state)

    def close(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.kill()
            self._proc.wait(timeout=5)
        shutil.rmtree(self.dir, ignore_errors=True)

    def __enter__(self) -> "Sandbox":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()


class Snapshot:
    """A fork point (s05). Restoring never consumes it."""

    def __init__(self, mem: pathlib.Path, state: pathlib.Path):
        self.mem, self.state = mem, state

    def restore(self) -> Sandbox:
        sbx = Sandbox(boot=False)
        sbx._spawn()
        # /snapshot/load is pre-boot only — nothing else may be configured
        # first, because everything the machine was comes back from the
        # files. Including its vsock device, whose socket path points at a
        # directory that no longer exists; vsock_override repoints it.
        sbx._api("/snapshot/load", {
            "snapshot_path": str(self.state),
            "mem_file_path": str(self.mem),
            "resume_vm": True,
            "vsock_override": {"uds_path": str(sbx.vsock)},
        })
        return sbx

    def fork(self, n: int) -> list[Sandbox]:
        """n machines with the same past and separate futures."""
        return [self.restore() for _ in range(n)]

    @property
    def size_mib(self) -> float:
        return os.path.getsize(self.mem) / 1024 / 1024
