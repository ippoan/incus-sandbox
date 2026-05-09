#!/usr/bin/env bash
# build.sh — worktree のソースを Incus 内 builder instance で cargo build する。
#
# Usage:
#   bash bin/build.sh <project> <worktree-name> [--bin <name>]
#
# 仕組み:
#   - <project>-<worktree> 専用 builder instance (incus-dev-warm 派生) を上げる (無ければ作る)
#     インスタンス名: alc-<project>-<wt>-builder
#   - host worktree を /src に bind-mount、target volume を /src/target に、
#     共有 cargo-registry を /root/.cargo/registry にマウント
#   - cargo build --release --bins (or 指定 bin) を中で実行
#   - exit 後も builder は残しておき、次回ビルドはキャッシュ効いて高速

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_lib.sh"

usage() {
  cat <<EOF
Usage: bash bin/build.sh <project> <worktree-name> [--bin <binary-name>]

Builds Rust binaries for the worktree using a persistent Incus builder instance.

Arguments:
  <project>        e.g. rust-alc-api  (must have projects/<project>/manifest.yaml)
  <worktree-name>  e.g. feat-foo      (.claude/worktrees/feat-foo must exist)

Options:
  --bin <name>     build only the specified binary (default: --bins, all)
  --keep           do not stop the builder after build (default behaviour)
  --stop           stop the builder after build (saves memory)
  -h | --help      show this message
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }

PROJECT="$1"; shift
WT="$1"; shift
BIN_FILTER=""
KEEP=1   # default: leave builder running for fast next iter

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin)   BIN_FILTER="$2"; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    --stop)  KEEP=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

require_incus
require_yq
need_cmd jq

WORKTREE_PATH="$(resolve_worktree_path "$PROJECT" "$WT")"
INCUS_PROJECT="$(incus_project_name "$PROJECT" "$WT")"
TARGET_VOLUME="$(target_volume_name "$PROJECT" "$WT")"
BUILDER_NAME="builder"

info "project=$PROJECT worktree=$WT path=$WORKTREE_PATH"
info "incus project=$INCUS_PROJECT  target volume=$TARGET_VOLUME"

# ---- ensure incus project + volumes ----
if ! incus_project_exists "$INCUS_PROJECT"; then
  info "creating incus project $INCUS_PROJECT"
  incus project create "$INCUS_PROJECT" \
    -c features.profiles=false \
    -c features.images=false \
    -c features.storage.volumes=false \
    -c features.networks=false
fi

if ! incus_volume_exists default "$TARGET_VOLUME"; then
  info "creating cargo target volume $TARGET_VOLUME"
  incus storage volume create default "$TARGET_VOLUME" --type=filesystem
fi

# ---- ensure builder instance ----
if ! incus_instance_exists "$INCUS_PROJECT" "$BUILDER_NAME"; then
  info "launching builder instance"
  incus init incus-dev-warm "$BUILDER_NAME" \
    --project "$INCUS_PROJECT" \
    --profile default \
    --profile alc-base
  # source bind-mount (host worktree)
  # shift=true: Incus が UID を自動マップ (host yhonda ↔ container root) して
  # コンテナ内 root が書ける状態にする。kernel 5.12+ の idmapped mounts 必須。
  incus config device add "$BUILDER_NAME" src disk \
    source="$WORKTREE_PATH" path=/src shift=true \
    --project "$INCUS_PROJECT" >/dev/null
  # cargo target volume
  # cargo target は /target に分離 (worktree の /src と被らせない、LXC の
  # rootfs 上の bind-mount + overlay を避ける)。CARGO_TARGET_DIR で誘導する。
  incus config device add "$BUILDER_NAME" target disk \
    pool=default source="$TARGET_VOLUME" path=/target \
    --project "$INCUS_PROJECT" >/dev/null
  # shared cargo registry
  incus config device add "$BUILDER_NAME" cargo-cache disk \
    pool=default source=cargo-registry path=/root/.cargo/registry \
    --project "$INCUS_PROJECT" >/dev/null
  # sccache 共有 cache (全 worktree で hit させる)
  incus config device add "$BUILDER_NAME" sccache disk \
    pool=default source=sccache-cache path=/sccache \
    --project "$INCUS_PROJECT" >/dev/null
  incus start "$BUILDER_NAME" --project "$INCUS_PROJECT"
  wait_for_cloud_init "$INCUS_PROJECT" "$BUILDER_NAME"
else
  state="$(incus list --project "$INCUS_PROJECT" --format=csv -c ns "$BUILDER_NAME" | cut -d, -f2 || true)"
  if [[ "$state" != "RUNNING" ]]; then
    info "starting existing builder"
    incus start "$BUILDER_NAME" --project "$INCUS_PROJECT"
  fi
fi

# ---- run cargo build ----
build_args=(--release)
if [[ -n "$BIN_FILTER" ]]; then
  build_args+=(--bin "$BIN_FILTER")
else
  build_args+=(--bins)
fi

info "cargo build ${build_args[*]} (in $INCUS_PROJECT/$BUILDER_NAME)"
incus exec "$BUILDER_NAME" --project "$INCUS_PROJECT" \
  --env CARGO_HOME=/root/.cargo \
  --env CARGO_TARGET_DIR=/target \
  --env RUSTC_WRAPPER=sccache \
  --env SCCACHE_DIR=/sccache \
  --cwd /src \
  -- bash -lc "cargo build ${build_args[*]}"

ok "build done"
incus exec "$BUILDER_NAME" --project "$INCUS_PROJECT" -- \
  bash -lc 'sccache --show-stats 2>/dev/null | head -20' || true
incus exec "$BUILDER_NAME" --project "$INCUS_PROJECT" -- \
  bash -lc 'ls -la /target/release/ 2>/dev/null | grep -E "^-.+x" | awk "{print \$NF}" | head -20' || true

if [[ "$KEEP" -eq 0 ]]; then
  info "stopping builder (--stop)"
  incus stop "$BUILDER_NAME" --project "$INCUS_PROJECT"
fi
