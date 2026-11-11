#!/usr/bin/env bash
set -euo pipefail

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$src_dir/../.." && pwd)"
builtin_dir="$repo_root/koreader/aidoku.koplugin/builtin_sources"

cd "$src_dir"
cargo build --release --target wasm32-unknown-unknown

stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

mkdir -p "$stage_dir/Payload"
cp -f "$src_dir/res/"* "$stage_dir/Payload/"
cp -f "$src_dir/target/wasm32-unknown-unknown/release/kox.wasm" "$stage_dir/Payload/main.wasm"

out_aix="$src_dir/kox-v1.aix"
rm -f "$out_aix"
(cd "$stage_dir" && zip -q -r "$out_aix" Payload)

mkdir -p "$builtin_dir"
cp -f "$out_aix" "$builtin_dir/kox-v1.aix"
echo "Packaged $out_aix and copied to $builtin_dir/kox-v1.aix ($(du -h "$out_aix" | cut -f1))"
