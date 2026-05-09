#!/usr/bin/env bash
# exec.sh — Incus instance に shell 接続するショートカット。
#
# Usage:
#   bash bin/exec.sh <project> <worktree-name> <instance>            # 対話 shell
#   bash bin/exec.sh <project> <worktree-name> <instance> -- <cmd>   # one-shot
#
# Examples:
#   bash bin/exec.sh rust-alc-api feat-foo backend
#   bash bin/exec.sh rust-alc-api feat-foo postgres -- psql -U postgres -c "\dt alc_api.*"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_lib.sh"

usage() {
  cat <<EOF
Usage:
  bash bin/exec.sh <project> <worktree-name> <instance>
  bash bin/exec.sh <project> <worktree-name> <instance> -- <cmd...>
EOF
}

[[ $# -ge 3 ]] || { usage; exit 1; }
PROJECT="$1"; WT="$2"; INSTANCE="$3"; shift 3

require_incus
INCUS_PROJECT="$(incus_project_name "$PROJECT" "$WT")"

if [[ $# -eq 0 ]]; then
  exec incus exec "$INSTANCE" --project "$INCUS_PROJECT" -- bash -l
fi

# strip leading --
[[ "${1:-}" == "--" ]] && shift
exec incus exec "$INSTANCE" --project "$INCUS_PROJECT" -- "$@"
