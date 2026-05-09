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
install_pkg iptables-persistent

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

# Docker と Incus の iptables 共存対策。
# Docker が FORWARD policy=DROP にするため、alcbr0 の outbound (apt/curl 等) が
# 全部 drop される。DOCKER-USER に明示的 ACCEPT を入れて永続化。
if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  added=0
  for direction in i o; do
    if ! iptables -C DOCKER-USER -${direction} alcbr0 -j ACCEPT 2>/dev/null; then
      iptables -I DOCKER-USER -${direction} alcbr0 -j ACCEPT
      added=1
    fi
  done
  if [[ $added -eq 1 ]]; then
    info "added iptables DOCKER-USER ACCEPT rules for alcbr0"
    netfilter-persistent save >/dev/null 2>&1 || true
  else
    ok "iptables DOCKER-USER rules already present"
  fi
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

# ---- 6. shared cache volumes ----
# 全 worktree / 全 warm image build で使い回す cache 群。
for vol in cargo-registry sccache-cache apt-cache rustup-cache; do
  if ! incus_volume_exists default "$vol"; then
    info "creating shared volume $vol"
    incus storage volume create default "$vol" --type=filesystem
  else
    ok "volume $vol exists"
  fi
done

# ---- 7,8. warm images ----
build_warm_image() {
  local alias="$1" base="$2" cloud_init_file="$3" marker="$4"
  local mount_caches="${5:-yes}"   # apt + rustup cache を attach するか (Ubuntu のみ yes)
  if incus_image_alias_exists "$alias"; then
    ok "warm image $alias exists, skipping (delete it to rebuild)"
    return 0
  fi
  info "building warm image $alias from $base"
  local tmp_name="${alias}-tmp"
  if incus list --format=csv 2>/dev/null | cut -d, -f1 | grep -qx "$tmp_name"; then
    incus delete -f "$tmp_name"
  fi

  # init (start しない)、cache device を attach してから start する。
  incus init "$base" "$tmp_name" \
    --config "user.user-data=$(cat "$cloud_init_file")" \
    --profile default --profile alc-base

  if [[ "$mount_caches" == "yes" ]]; then
    # apt cache: /var/cache/apt/archives を shared volume に
    incus config device add "$tmp_name" apt-cache disk \
      pool=default source=apt-cache path=/var/cache/apt/archives >/dev/null
    # rustup toolchain cache: /cache/rustup を shared volume に。
    # cloud-init runcmd で /root/.rustup ↔ /cache/rustup を相互コピーする。
    incus config device add "$tmp_name" rustup-cache disk \
      pool=default source=rustup-cache path=/cache/rustup >/dev/null
  fi

  incus start "$tmp_name"

  info "waiting for cloud-init in $tmp_name (this can take a few minutes)"
  local i=0
  until incus exec "$tmp_name" -- test -f "$marker" 2>/dev/null; do
    i=$((i + 1))
    [[ $i -le 600 ]] || die "timed out building $alias (cloud-init not done)"
    sleep 2
  done

  info "stopping $tmp_name and publishing as $alias"
  incus stop "$tmp_name"
  # publish 前に cache device を外す (image rootfs に余計な mount 情報を残さない)
  for dev in apt-cache rustup-cache; do
    incus config device remove "$tmp_name" "$dev" 2>/dev/null || true
  done
  incus publish "$tmp_name" --alias "$alias"
  incus delete "$tmp_name"
  ok "warm image $alias ready"
}

# cloud 版 (`/cloud` suffix) は cloud-init を同梱する。minimal 版は cloud-init なし。
# Ubuntu 側は apt + rustup cache を活用するので mount_caches=yes
build_warm_image incus-dev-warm \
  images:ubuntu/noble/cloud \
  "${SANDBOX_ROOT}/cloud-init/ubuntu-app.yaml" \
  /var/lib/incus-sandbox-warm-ready \
  yes

# Debian/postgres は apt しか使わないので apt-cache だけでも嬉しいが、
# 構造保ちつつ no にして簡素化 (postgres は再 build 頻度が低い)
build_warm_image incus-dev-warm-pg \
  images:debian/12/cloud \
  "${SANDBOX_ROOT}/cloud-init/debian-postgres.yaml" \
  /var/lib/incus-sandbox-warm-ready \
  no

ok "init complete. next: bash bin/build.sh <project> <worktree-name>"
