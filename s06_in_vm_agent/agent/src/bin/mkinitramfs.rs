//! mkinitramfs — write a newc cpio archive, which is all an initramfs is.
//!
//! The kernel unpacks this into a tmpfs before any filesystem or block
//! device exists, then runs /init from it. That is how a binary gets into
//! a machine with no network and a read-only disk.
//!
//! The format is from 1977 and has not needed to change: a flat sequence
//! of [110-byte header][name][data], each padded to four bytes, ending
//! with an entry named TRAILER!!!. Every header field is ASCII hex, which
//! is why there is no endianness question — the same bytes parse the same
//! way on x86 and ARM.
//!
//! The kernel chose this over tar (several incompatible dialects) and zip
//! (its index lives at the end, so you would have to seek) because it can
//! be parsed streaming, in a few hundred lines, with nothing else around.
//!
//! Usage: mkinitramfs <out.cpio> <path-in-archive>=<file-on-disk> ...

use std::fs;
use std::io::Write;

const MODE_DIR: u32 = 0o040_755;
const MODE_EXE: u32 = 0o100_755;

/// One record: the fixed header, the name, the data, each 4-byte aligned.
fn entry(out: &mut Vec<u8>, name: &str, data: &[u8], mode: u32, ino: u32) {
    let name_z = format!("{name}\0");
    // 13 fields after the magic, eight ASCII hex digits each.
    let header = format!(
        "070701{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}{:08X}",
        ino,            // inode
        mode,           // type and permissions
        0,              // uid
        0,              // gid
        1,              // nlink
        0,              // mtime — zero keeps the archive reproducible
        data.len(),     // filesize
        0, 0, 0, 0,     // dev/rdev major and minor
        name_z.len(),   // namesize, including the trailing NUL
        0,              // check — always zero in newc
    );
    out.extend_from_slice(header.as_bytes());
    out.extend_from_slice(name_z.as_bytes());
    pad(out);
    out.extend_from_slice(data);
    pad(out);
}

fn pad(out: &mut Vec<u8>) {
    while out.len() % 4 != 0 {
        out.push(0);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: {} <out.cpio> <name-in-archive>=<file> ...", args[0]);
        std::process::exit(2);
    }

    let mut archive = Vec::new();
    let mut ino = 2u32; // 0 and 1 are conventionally left alone
    let mut made_dirs: Vec<String> = Vec::new();

    for spec in &args[2..] {
        let (name, path) = spec.split_once('=').unwrap_or_else(|| {
            eprintln!("expected name=path, got {spec:?}");
            std::process::exit(2);
        });

        // A file at bin/busybox needs a bin/ entry before it: the unpacker
        // creates entries in the order it meets them and will not invent a
        // parent directory.
        if let Some((dir, _)) = name.rsplit_once('/') {
            if !made_dirs.contains(&dir.to_string()) {
                entry(&mut archive, dir, &[], MODE_DIR, ino);
                ino += 1;
                made_dirs.push(dir.to_string());
            }
        }

        let data = fs::read(path).unwrap_or_else(|e| {
            eprintln!("cannot read {path}: {e}");
            std::process::exit(1);
        });
        entry(&mut archive, name, &data, MODE_EXE, ino);
        ino += 1;
        println!("  {:<16} {:>9} bytes", name, data.len());
    }

    entry(&mut archive, "TRAILER!!!", &[], 0, 0);

    let mut f = fs::File::create(&args[1]).expect("create archive");
    f.write_all(&archive).expect("write archive");
    println!("  {:<16} {:>9} bytes total", args[1], archive.len());
}
