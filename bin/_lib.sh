#!/usr/bin/env bash
# Shared helpers for incus-sandbox bin/* scripts.
# Source this file from every bin/<cmd>.sh:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

set -euo pipefail

# --- paths ---
SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOCATIONS_FILE="${SANDBOX_ROOT}/allocations/ports.json"
PORT_BASE=18080
PORT_MAX=18999

# --- logging ---
info() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- prerequisites ---
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_incus() {
  need_cmd incus
  incus info >/dev/null 2>&1 || die "incus not initialised, run: sudo bash bin/init.sh"
}

require_yq() {
  need_cmd yq
  # Mike Farah's yq v4+. apt の python-yq とは別物。
  if ! yq --version 2>&1 | grep -qE 'mikefarah|version v?4'; then
    die "yq v4 (mikefarah) required. python-yq is not compatible. See README."
  fi
}

# --- naming helpers ---
# Sanitize an arbitrary string into a valid Incus name component.
# Lowercase, alnum + hyphen, max 50 chars. Uses tr + sed.
sanitize() {
  local s="$1"
  s="$(printf '%s' "$s" | tr 'A-Z' 'a-z')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s:0:50}"
}

# Incus project name for a (project, worktree) pair.
incus_project_name() {
  local project="$1" wt="$2"
  printf 'alc-%s-%s' "$(sanitize "$project")" "$(sanitize "$wt")"
}

target_volume_name() {
  local project="$1" wt="$2"
  printf 'cargo-target-%s-%s' "$(sanitize "$project")" "$(sanitize "$wt")"
}

# (postgres data は揮発、専用 volume なし)

# --- worktree resolution ---
# Look up the on-disk path of a worktree using `git worktree list --porcelain`.
# Project source repo is determined from manifest's `worktree_root` (which is
# typically `<repo>/.claude/worktrees`).
resolve_worktree_path() {
  local project="$1" wt="$2"
  local manifest worktree_root expanded
  manifest="$(manifest_path "$project")"
  [[ -f "$manifest" ]] || die "manifest not found: $manifest"
  worktree_root="$(yq -r '.worktree_root' "$manifest")"
  # Expand ~ and env vars
  expanded="${worktree_root/#\~/$HOME}"
  local candidate="${expanded}/${wt}"
  [[ -d "$candidate" ]] || die "worktree dir not found: $candidate (create with: git worktree add -b <branch> $candidate origin/main)"
  printf '%s' "$candidate"
}

manifest_path() {
  printf '%s/projects/%s/manifest.yaml' "$SANDBOX_ROOT" "$1"
}

# --- port allocation ---
# allocations/ports.json schema:
#   { "<project>": { "<wt>": <port>, ... }, ... }
# Mutex via flock on the file itself.

_ensure_alloc_file() {
  mkdir -p "$(dirname "$ALLOCATIONS_FILE")"
  [[ -f "$ALLOCATIONS_FILE" ]] || echo '{}' >"$ALLOCATIONS_FILE"
}

# Get already-allocated port for (project, wt), or empty string if none.
port_get() {
  local project="$1" wt="$2"
  _ensure_alloc_file
  jq -r --arg p "$project" --arg w "$wt" \
    '.[$p][$w] // empty' "$ALLOCATIONS_FILE"
}

# Allocate (or return existing) host port for (project, wt).
port_alloc() {
  local project="$1" wt="$2"
  _ensure_alloc_file
  need_cmd jq

  local existing
  existing="$(port_get "$project" "$wt")"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi

  # find smallest free port >= PORT_BASE
  exec 9>"${ALLOCATIONS_FILE}.lock"
  flock 9
  trap 'flock -u 9; exec 9>&-' RETURN

  local used candidate=$PORT_BASE
  used="$(jq -r '[.[][]?] | map(tostring) | join(" ")' "$ALLOCATIONS_FILE")"
  while [[ $candidate -le $PORT_MAX ]]; do
    if ! grep -qw "$candidate" <<<"$used"; then
      break
    fi
    candidate=$((candidate + 1))
  done
  [[ $candidate -le $PORT_MAX ]] || die "port range exhausted ($PORT_BASE..$PORT_MAX)"

  local tmp
  tmp="$(mktemp)"
  jq --arg p "$project" --arg w "$wt" --argjson port "$candidate" \
    '.[$p] = (.[$p] // {}) | .[$p][$w] = $port' \
    "$ALLOCATIONS_FILE" >"$tmp"
  mv "$tmp" "$ALLOCATIONS_FILE"
  printf '%s' "$candidate"
}

# Release a port allocation.
port_release() {
  local project="$1" wt="$2"
  _ensure_alloc_file
  need_cmd jq

  exec 9>"${ALLOCATIONS_FILE}.lock"
  flock 9
  trap 'flock -u 9; exec 9>&-' RETURN

  local tmp
  tmp="$(mktemp)"
  jq --arg p "$project" --arg w "$wt" \
    'if .[$p] then del(.[$p][$w]) else . end | with_entries(select(.value != {}))' \
    "$ALLOCATIONS_FILE" >"$tmp"
  mv "$tmp" "$ALLOCATIONS_FILE"
}

# --- incus convenience ---
incus_project_exists() {
  incus project list --format=csv 2>/dev/null | cut -d, -f1 | grep -qx "$1"
}

incus_volume_exists() {
  local pool="${1:-default}" name="$2"
  incus storage volume list "$pool" --format=csv 2>/dev/null | cut -d, -f2 | grep -qx "$name"
}

incus_image_alias_exists() {
  incus image alias list --format=csv 2>/dev/null | cut -d, -f1 | grep -qx "$1"
}

incus_instance_exists() {
  local project="$1" name="$2"
  incus list --project "$project" --format=csv 2>/dev/null | cut -d, -f1 | grep -qx "$name"
}

# Wait until the cloud-init marker file exists in an instance.
wait_for_cloud_init() {
  local project="$1" instance="$2" marker="${3:-/var/lib/incus-sandbox-warm-ready}"
  local i=0
  until incus exec --project "$project" "$instance" -- test -f "$marker" 2>/dev/null; do
    i=$((i + 1))
    [[ $i -le 300 ]] || die "timed out waiting for cloud-init in $project/$instance"
    sleep 2
  done
}
