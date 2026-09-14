//! agent — the program that lives inside the machine.
//!
//! Everything so far has operated on microVMs from outside: start, freeze,
//! fork. None of it can ask one to run a command, because there was nobody
//! in there to ask.
//!
//! This is that somebody. It runs as PID 1 in an initramfs, listens on a
//! vsock port, and for each connection reads one command, runs it, and
//! streams the output straight back down the socket.
//!
//! Two constraints shape it:
//!
//!   * PID 1 may not exit. Not even successfully — the kernel panics with
//!     "Attempted to kill init!" and takes the machine with it.
//!   * There is no network. vsock is addressed by (CID, port) and needs no
//!     interface, no address, no routing, and no DNS.

use std::ffi::CString;

// ---------------------------------------------------------------------
// The syscalls we need. std links libc already, so these just name what is
// there. Declaring them by hand keeps the crate dependency-free and leaves
// every kernel call this program makes visible in one place.
// ---------------------------------------------------------------------
extern "C" {
    fn socket(domain: i32, ty: i32, protocol: i32) -> i32;
    fn bind(fd: i32, addr: *const SockAddrVm, len: u32) -> i32;
    fn listen(fd: i32, backlog: i32) -> i32;
    fn accept(fd: i32, addr: *mut SockAddrVm, len: *mut u32) -> i32;
    fn read(fd: i32, buf: *mut u8, n: usize) -> isize;
    fn write(fd: i32, buf: *const u8, n: usize) -> isize;
    fn close(fd: i32) -> i32;
    fn dup2(old: i32, new: i32) -> i32;
    fn fork() -> i32;
    fn execv(path: *const i8, argv: *const *const i8) -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
    fn mount(src: *const i8, tgt: *const i8, fstype: *const i8, flags: u64, data: *const i8) -> i32;
    fn mkdir(path: *const i8, mode: u32) -> i32;
    fn _exit(code: i32) -> !;
}

const AF_VSOCK: i32 = 40;
const SOCK_STREAM: i32 = 1;
const VMADDR_CID_ANY: u32 = 0xffff_ffff;
const PORT: u32 = 1234;

/// struct sockaddr_vm — the whole of vsock addressing. No host, no port
/// number that a router could ever see: a context id and a port, sixteen
/// bytes, and the hypervisor does the rest.
#[repr(C)]
struct SockAddrVm {
    svm_family: u16,
    svm_reserved1: u16,
    svm_port: u32,
    svm_cid: u32,
    svm_zero: [u8; 4],
}

fn cstr(s: &str) -> CString {
    CString::new(s).expect("no interior nul")
}

/// Give the guest the couple of filesystems that make commands useful.
/// Failures are ignored: if /proc is already there, or the kernel was built
/// without it, the agent still works for everything that does not need it.
fn mount_basics() {
    unsafe {
        for (src, tgt, fs) in [
            ("proc", "/proc", "proc"),
            ("sysfs", "/sys", "sysfs"),
            ("devtmpfs", "/dev", "devtmpfs"),
        ] {
            mkdir(cstr(tgt).as_ptr(), 0o755);
            mount(cstr(src).as_ptr(), cstr(tgt).as_ptr(), cstr(fs).as_ptr(), 0, std::ptr::null());
        }
    }
}

/// BusyBox is 400 commands in one binary, and it decides which one you
/// wanted by looking at argv[0] — the same trick that makes /usr/bin/sg
/// and newgrp the same program. With only /bin/busybox on disk, a shell
/// looking for `uname` finds nothing, so ask BusyBox to symlink every
/// applet it knows into /bin. The filesystem is a tmpfs, so this costs
/// nothing and disappears with the machine.
fn install_busybox() {
    // BusyBox installs each applet at its canonical path, so `ls` lands in
    // /bin but `head` wants /usr/bin. Without these directories those
    // symlinks silently fail and the shell reports "not found" for half
    // the commands it should have.
    unsafe {
        for d in ["/usr", "/usr/bin", "/usr/sbin", "/sbin"] {
            mkdir(cstr(d).as_ptr(), 0o755);
        }
    }
    let pid = unsafe { fork() };
    if pid == 0 {
        unsafe {
            let bb = cstr("/bin/busybox");
            let a0 = cstr("busybox");
            let a1 = cstr("--install");
            let a2 = cstr("-s");
            let argv = [bb.as_ptr(), a0.as_ptr(), a1.as_ptr(), a2.as_ptr(), std::ptr::null()];
            execv(bb.as_ptr(), argv.as_ptr());
            _exit(127);
        }
    }
    let mut status: i32 = 0;
    unsafe { waitpid(pid, &mut status, 0) };
}

fn say(fd: i32, s: &str) {
    unsafe { write(fd, s.as_ptr(), s.len()) };
}

/// Run one command with its output wired directly to the socket, so the
/// caller sees it as it happens rather than when it finishes.
fn run_command(conn: i32, cmd: &str) {
    let pid = unsafe { fork() };
    if pid == 0 {
        unsafe {
            // The child speaks to the caller by being the caller's stdout.
            dup2(conn, 1);
            dup2(conn, 2);
            let sh = cstr("/bin/busybox");
            let a0 = cstr("sh");
            let a1 = cstr("-c");
            let a2 = cstr(cmd);
            let argv = [sh.as_ptr(), a0.as_ptr(), a1.as_ptr(), a2.as_ptr(), std::ptr::null()];
            execv(sh.as_ptr(), argv.as_ptr());
            _exit(127); // only reached if execv failed
        }
    }
    let mut status: i32 = 0;
    unsafe { waitpid(pid, &mut status, 0) };
    let code = (status >> 8) & 0xff;
    say(conn, &format!("\n[exit {code}]\n"));
}

fn main() {
    mount_basics();
    install_busybox();
    println!("agent: up, listening on vsock port {PORT}");

    let sock = unsafe { socket(AF_VSOCK, SOCK_STREAM, 0) };
    if sock < 0 {
        println!("agent: no AF_VSOCK — is the vsock device attached?");
        park();
    }

    let addr = SockAddrVm {
        svm_family: AF_VSOCK as u16,
        svm_reserved1: 0,
        svm_port: PORT,
        svm_cid: VMADDR_CID_ANY,
        svm_zero: [0; 4],
    };
    unsafe {
        if bind(sock, &addr, std::mem::size_of::<SockAddrVm>() as u32) < 0 {
            println!("agent: bind failed");
            park();
        }
        listen(sock, 8);
    }

    loop {
        let conn = unsafe { accept(sock, std::ptr::null_mut(), std::ptr::null_mut()) };
        if conn < 0 {
            continue;
        }
        // One command per connection, newline terminated.
        let mut buf = [0u8; 4096];
        let n = unsafe { read(conn, buf.as_mut_ptr(), buf.len()) };
        if n > 0 {
            let cmd = String::from_utf8_lossy(&buf[..n as usize]).trim().to_string();
            println!("agent: running {cmd:?}");
            run_command(conn, &cmd);
        }
        unsafe { close(conn) };
    }
}

/// PID 1 is not allowed to return. If something went wrong badly enough
/// that we cannot serve, sit still and let the host decide what to do —
/// exiting here would panic the kernel and destroy the evidence.
fn park() -> ! {
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
