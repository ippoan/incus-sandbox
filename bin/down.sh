#!/usr/bin/env bash
# down.sh — worktree 用 Incus サンドボックスを停止 / 削除する。
#
# Usage:
#   bash bin/down.sh <project> <worktree-name>          # instance 削除、volume 残す
#   bash bin/down.sh <project> <worktree-name> --purge  # volume も削除
#   bash bin/down.sh <project> <worktree-name> --stop   # 停止のみ (instance 残す)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_lib.sh"

usage() {
  cat <<EOF
Usage: bash bin/down.sh <project> <worktree-name> [--purge | --stop]

  (no flag)  stop + delete instances, keep volumes (cargo target / pgdata) and project
  --purge    stop + delete instances + delete volumes + delete project + free port
  --stop     stop instances only (no delete)
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }
PROJECT="$1"; WT="$2"; ACTION="${3:-delete-instances}"

require_incus

INCUS_PROJECT="$(incus_project_name "$PROJECT" "$WT")"
TARGET_VOLUME="$(target_volume_name "$PROJECT" "$WT")"

if ! incus_project_exists "$INCUS_PROJECT"; then
  warn "project $INCUS_PROJECT does not exist, nothing to do"
  exit 0
fi

mapfile -t INSTANCES < <(incus list --project "$INCUS_PROJECT" --format=csv -c n)

case "$ACTION" in
  --stop)
    for i in "${INSTANCES[@]}"; do
      info "stopping $i"
      incus stop "$i" --project "$INCUS_PROJECT" --force || true
    done
    ;;
  delete-instances)
    # postgres data は instance と一緒に消える (揮発)。
    # cargo target volume は残す (cold build を避けるため)。
    for i in "${INSTANCES[@]}"; do
      info "deleting $i"
      incus delete "$i" --project "$INCUS_PROJECT" --force || true
    done
    ok "instances deleted, cargo target volume preserved (use --purge to wipe target too)"
    ;;
  --purge)
    for i in "${INSTANCES[@]}"; do
      info "deleting $i"
      incus delete "$i" --project "$INCUS_PROJECT" --force || true
    done
    if incus_volume_exists default "$TARGET_VOLUME"; then
      info "deleting volume $TARGET_VOLUME"
      incus storage volume delete default "$TARGET_VOLUME" || true
    fi
    info "deleting project $INCUS_PROJECT"
    incus project delete "$INCUS_PROJECT" || true
    port_release "$PROJECT" "$WT"
    ok "purged ${INCUS_PROJECT}"
    ;;
  *) usage; die "unknown flag: $ACTION" ;;
esac
