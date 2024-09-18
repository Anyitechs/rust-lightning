#!/bin/sh
set -e
set -x
echo "Testing $(git log -1 --oneline)"
cargo check
cargo doc
cargo doc --document-private-items
cd fuzz && RUSTFLAGS="--cfg=fuzzing --cfg=secp256k1_fuzz --cfg=hashes_fuzz" cargo check --features=stdin_fuzz
cd ../lightning && cargo check --no-default-features
cd .. && RUSTC_BOOTSTRAP=1 RUSTFLAGS="--cfg=c_bindings" cargo check -Z avoid-dev-deps
