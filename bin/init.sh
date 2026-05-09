#!/usr/bin/env bash
# init.sh — 1 度だけ実行する全体セットアップ。
#
# やること:
#   1. 必須ツール (incus, yq, jq, git) の確認 / インストール
#   2. incus admin init --minimal
#   3. ユーザーを incus-admin グループに追加
#   4. bridge alcbr0 作成 (DNS managed)
#   5. profile 4 種 (alc-base / alc-app / alc-postgres / alc-gateway) を作成
#   6. shared volume cargo-registry を作成
#   7. warm image incus-dev-warm (ubuntu/24.04 + cloud-init/ubuntu-app.yaml) を作成
#   8. warm image incus-dev-warm-pg (debian/12 + cloud-init/debian-postgres.yaml) を作成
#
# Usage:
#   sudo bash bin/init.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_lib.sh"

if [[ $EUID -ne 0 ]]; then
  die "init.sh must run as root: sudo bash bin/init.sh"
fi

# ---- 1. install prerequisites ----
install_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    info "apt install $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"
  fi
}

info "checking apt prerequisites"
apt-get update -qq
install_pkg incus
install_pkg jq
install_pkg git

# yq mikefarah v4: not in apt as that name; use snap or download.
# apt の "yq" は python-yq で文法が違う。明示的に mikefarah 版を入れる。
if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -qE 'mikefarah'; then
  info "installing mikefarah/yq v4 from GitHub release"
  YQ_VERSION="${YQ_VERSION:-v4.44.3}"
  arch="$(dpkg --print-architecture)"
  curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"
  chmod 0755 /usr/local/bin/yq
fi

ok "tools ready: $(incus --version) / $(yq --version) / jq $(jq --version | tr -d '\n')"

# ---- 2. incus admin init / default storage pool ----
# `incus info` が通っても storage pool が未作成のことがある (apt install 直後)。
# pool が無ければ minimal init を走らせる。
if ! incus storage list --format=csv 2>/dev/null | grep -q '^default,'; then
  info "running incus admin init --minimal (no default storage pool found)"
  incus admin init --minimal
else
  ok "incus initialised (default storage pool present)"
fi

# ---- 3. user group ----
if [[ -n "${SUDO_USER:-}" ]]; then
  if ! id -nG "$SUDO_USER" | tr ' ' '\n' | grep -qx incus-admin; then
    info "adding $SUDO_USER to incus-admin group"
    usermod -aG incus-admin "$SUDO_USER"
    warn "$SUDO_USER must run 'newgrp incus-admin' or re-login for group to take effect"
  fi
fi

# ---- 4. bridge alcbr0 ----
if ! incus network list --format=csv 2>/dev/null | cut -d, -f1 | grep -qx alcbr0; then
  info "creating network alcbr0"
  incus network create alcbr0 \
    ipv4.address=10.150.0.1/24 \
    ipv4.nat=true \
    ipv6.address=none \
    dns.mode=managed \
    dns.domain=incus
else
  ok "network alcbr0 exists"
fi

# ---- 5. profiles ----
load_profile() {
  local name="$1" file="$2"
  if incus profile list --format=csv 2>/dev/null | cut -d, -f1 | grep -qx "$name"; then
    info "updating profile $name"
    incus profile edit "$name" <"$file"
  else
    info "creating profile $name"
    incus profile create "$name"
    incus profile edit "$name" <"$file"
  fi
}

load_profile alc-base     "${SANDBOX_ROOT}/profiles/base.yaml"
load_profile alc-app      "${SANDBOX_ROOT}/profiles/app.yaml"
load_profile alc-postgres "${SANDBOX_ROOT}/profiles/postgres.yaml"
load_profile alc-gateway  "${SANDBOX_ROOT}/profiles/gateway.yaml"

# ---- 6. cargo-registry shared volume ----
if ! incus_volume_exists default cargo-registry; then
  info "creating shared volume cargo-registry"
  incus storage volume create default cargo-registry --type=filesystem
else
  ok "volume cargo-registry exists"
fi

# ---- 7,8. warm images ----
build_warm_image() {
  local alias="$1" base="$2" cloud_init_file="$3" marker="$4"
  if incus_image_alias_exists "$alias"; then
    ok "warm image $alias exists, skipping (delete it to rebuild)"
    return 0
  fi
  info "building warm image $alias from $base"
  local tmp_name="${alias}-tmp"
  if incus list --format=csv 2>/dev/null | cut -d, -f1 | grep -qx "$tmp_name"; then
    incus delete -f "$tmp_name"
  fi

  incus launch "$base" "$tmp_name" \
    --config "user.user-data=$(cat "$cloud_init_file")" \
    --profile default

  info "waiting for cloud-init in $tmp_name (this can take a few minutes)"
  local i=0
  until incus exec "$tmp_name" -- test -f "$marker" 2>/dev/null; do
    i=$((i + 1))
    [[ $i -le 600 ]] || die "timed out building $alias (cloud-init not done)"
    sleep 2
  done

  info "stopping $tmp_name and publishing as $alias"
  incus stop "$tmp_name"
  incus publish "$tmp_name" --alias "$alias"
  incus delete "$tmp_name"
  ok "warm image $alias ready"
}

build_warm_image incus-dev-warm \
  images:ubuntu/24.04 \
  "${SANDBOX_ROOT}/cloud-init/ubuntu-app.yaml" \
  /var/lib/incus-sandbox-warm-ready

build_warm_image incus-dev-warm-pg \
  images:debian/12 \
  "${SANDBOX_ROOT}/cloud-init/debian-postgres.yaml" \
  /var/lib/incus-sandbox-warm-ready

ok "init complete. next: bash bin/build.sh <project> <worktree-name>"
