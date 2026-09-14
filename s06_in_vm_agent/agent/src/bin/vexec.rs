//! vexec — run a command inside a microVM, from the host.
//!
//! The guest's agent listens on AF_VSOCK. The host does not speak AF_VSOCK
//! to it directly: Firecracker proxies the whole thing through a Unix
//! socket, with a two-line handshake of its own.
//!
//!     host: connect to uds_path
//!     host: send  "CONNECT 1234\n"
//!     host: read  "OK <host-side-port>\n"
//!     ... from here the socket is wired to the guest's accepted connection
//!
//! Notice what is absent on this side: no unsafe, no extern declarations,
//! no syscall constants. A Unix socket is ordinary enough that std already
//! has it — which is the difference between being outside the machine and
//! being inside it.
//!
//! Usage: vexec <uds_path> <port> <command...>

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: {} <uds_path> <port> <command...>", args[0]);
        std::process::exit(2);
    }
    let (uds, port, command) = (&args[1], &args[2], args[3..].join(" "));

    let mut sock = UnixStream::connect(uds).unwrap_or_else(|e| {
        eprintln!("cannot reach the VMM at {uds}: {e}");
        std::process::exit(1);
    });

    // Handshake. Firecracker answers "OK <port>" once it has found someone
    // listening in the guest, and simply closes the connection if it has not.
    write!(sock, "CONNECT {port}\n").expect("send CONNECT");
    let mut reader = BufReader::new(sock.try_clone().expect("dup socket"));
    let mut ack = String::new();
    reader.read_line(&mut ack).expect("read handshake");
    if !ack.starts_with("OK") {
        eprintln!("handshake refused: {:?} — is the agent listening on {port}?", ack.trim());
        std::process::exit(1);
    }

    // Past the handshake this is a plain byte stream to the process the
    // agent is about to fork.
    writeln!(sock, "{command}").expect("send command");
    sock.flush().ok();

    let mut out = Vec::new();
    reader.read_to_end(&mut out).expect("read reply");
    std::io::stdout().write_all(&out).expect("write output");
}
