#!/usr/bin/env bash
# port.sh — worktree に割り当てられた host port を表示する。
#
# Usage:
#   bash bin/port.sh                             # 全 worktree の割当一覧
#   bash bin/port.sh <project> <worktree-name>   # 特定 worktree の port のみ

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_lib.sh"

if [[ $# -eq 0 ]]; then
  need_cmd jq
  if [[ -f "$ALLOCATIONS_FILE" ]]; then
    jq -r 'to_entries[] as $p | $p.value | to_entries[] | "\($p.key)\t\(.key)\t\(.value)"' \
      "$ALLOCATIONS_FILE" \
      | { printf 'PROJECT\tWORKTREE\tPORT\n'; cat; } \
      | column -t
  else
    echo "no allocations yet"
  fi
  exit 0
fi

[[ $# -eq 2 ]] || { echo "Usage: bash bin/port.sh [<project> <worktree-name>]" >&2; exit 1; }
port_get "$1" "$2"
