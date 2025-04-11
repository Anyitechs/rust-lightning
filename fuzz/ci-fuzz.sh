#!/bin/bash
set -e
set -x

pushd src/msg_targets
rm msg_*.rs
./gen_target.sh
[ "$(git diff)" != "" ] && exit 1
popd
pushd src/bin
rm *_target.rs
./gen_target.sh
[ "$(git diff)" != "" ] && exit 1
popd

export RUSTFLAGS="--cfg=secp256k1_fuzz --cfg=hashes_fuzz"

mkdir -p hfuzz_workspace/full_stack_target/input
pushd write-seeds
RUSTFLAGS="$RUSTFLAGS --cfg=fuzzing" cargo run ../hfuzz_workspace/full_stack_target/input
popd

cargo install --color always --force honggfuzz --no-default-features
# Because we're fuzzing relatively few iterations, the maximum possible
# compiler optimizations aren't necessary, so switch to defaults.
sed -i 's/lto = true//' Cargo.toml
sed -i 's/codegen-units = 1//' Cargo.toml

export HFUZZ_BUILD_ARGS="--features honggfuzz_fuzz"

cargo --color always hfuzz build
for TARGET in src/bin/*.rs; do
	FILENAME=$(basename $TARGET)
	FILE="${FILENAME%.*}"
	HFUZZ_RUN_ARGS="--exit_upon_crash -v -n2"
	if [ "$FILE" = "chanmon_consistency_target" ]; then
		HFUZZ_RUN_ARGS="$HFUZZ_RUN_ARGS -F 64 -N5000"
	elif [ "$FILE" = "process_network_graph_target" -o "$FILE" = "full_stack_target" -o "$FILE" = "router_target" ]; then
		HFUZZ_RUN_ARGS="$HFUZZ_RUN_ARGS -N50000"
	elif [ "$FILE" = "indexedmap_target" ]; then
		HFUZZ_RUN_ARGS="$HFUZZ_RUN_ARGS -N500000"
	else
		HFUZZ_RUN_ARGS="$HFUZZ_RUN_ARGS -N2500000"
	fi
	export HFUZZ_RUN_ARGS
	cargo --color always hfuzz run $FILE
	if [ -f hfuzz_workspace/$FILE/HONGGFUZZ.REPORT.TXT ]; then
		cat hfuzz_workspace/$FILE/HONGGFUZZ.REPORT.TXT
		for CASE in hfuzz_workspace/$FILE/SIG*; do
			cat $CASE | xxd -p
		done
		exit 1
	fi
done
