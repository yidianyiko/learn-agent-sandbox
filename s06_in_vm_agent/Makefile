# Keep the build inside this directory even when CARGO_TARGET_DIR is set
# in the environment, so the demo can find what it just built.
export CARGO_TARGET_DIR = $(CURDIR)/target
export RUSTFLAGS = -C target-feature=+crt-static

BINS = target/release/agent target/release/mkinitramfs target/release/vexec

all: $(BINS)

$(BINS): agent/src/main.rs agent/src/bin/mkinitramfs.rs agent/src/bin/vexec.rs agent/Cargo.toml
	cd agent && cargo build --release

run: all
	./demo.sh

clean:
	rm -rf target initramfs.cpio

.PHONY: all run clean
