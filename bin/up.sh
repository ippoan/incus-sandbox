#!/usr/bin/env bash
# up.sh — worktree 用 Incus サンドボックスを起動する。
#
# Usage:
#   bash bin/up.sh <project> <worktree-name> full
#   bash bin/up.sh <project> <worktree-name> solo <service>
#
# Steps:
#   1. manifest と worktree 解決
#   2. Incus project / target volume / pgdata volume を作成 (冪等)
#   3. host port を allocate
#   4. mode に応じた service リストを依存順に launch
#   5. systemd unit を inject、起動完了を待つ
#   6. gateway に host proxy device を後付けして 127.0.0.1:<port> で公開
#   7. frontend 接続用の hint を表示

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/_lib.sh"

usage() {
  cat <<EOF
Usage:
  bash bin/up.sh <project> <worktree-name> full
  bash bin/up.sh <project> <worktree-name> solo <service>

Examples:
  bash bin/up.sh rust-alc-api feat-foo full
  bash bin/up.sh rust-alc-api feat-foo solo backend
EOF
}

[[ $# -ge 3 ]] || { usage; exit 1; }
PROJECT="$1"; WT="$2"; MODE="$3"; SOLO_SVC="${4:-}"

require_incus
require_yq
need_cmd jq

MANIFEST="$(manifest_path "$PROJECT")"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

WORKTREE_PATH="$(resolve_worktree_path "$PROJECT" "$WT")"
INCUS_PROJECT="$(incus_project_name "$PROJECT" "$WT")"
TARGET_VOLUME="$(target_volume_name "$PROJECT" "$WT")"
# postgres data は揮発 (instance のエフェメラル FS に置く)。staging と同じセマンティクス。

# ---- resolve service list from mode ----
case "$MODE" in
  full)
    mapfile -t SERVICES < <(yq -r '.modes.full.instances[]' "$MANIFEST")
    ;;
  solo)
    [[ -n "$SOLO_SVC" ]] || { usage; die "solo mode requires <service>"; }
    yq -r '.services | keys | .[]' "$MANIFEST" | grep -qx "$SOLO_SVC" \
      || die "service not in manifest: $SOLO_SVC"
    # Mike Farah yq: env var を strenv で参照 (jq の --arg 互換は無い)
    mapfile -t SERVICES < <(
      svc="$SOLO_SVC" yq -r \
        '.modes.solo.instances[] | sub("<arg>", strenv(svc))' "$MANIFEST"
    )
    ;;
  *)
    usage; die "unknown mode: $MODE"
    ;;
esac

info "project=$PROJECT worktree=$WT mode=$MODE"
info "services: ${SERVICES[*]}"

# ---- ensure project / volumes ----
if ! incus_project_exists "$INCUS_PROJECT"; then
  info "creating incus project $INCUS_PROJECT"
  incus project create "$INCUS_PROJECT" \
    -c features.profiles=false \
    -c features.images=false \
    -c features.storage.volumes=false \
    -c features.networks=false
fi
incus_volume_exists default "$TARGET_VOLUME" \
  || incus storage volume create default "$TARGET_VOLUME" --type=filesystem

# ---- allocate host port ----
HOST_PORT="$(port_alloc "$PROJECT" "$WT")"
info "allocated host port: $HOST_PORT"

# ---- helpers ----
ensure_app_instance() {
  local name="$1" image_alias="${2:-incus-dev-warm}"
  if incus_instance_exists "$INCUS_PROJECT" "$name"; then
    return 0
  fi
  info "init $name from $image_alias"
  incus init "$image_alias" "$name" \
    --project "$INCUS_PROJECT" \
    --profile default \
    --profile alc-base
  incus config device add "$name" src disk \
    source="$WORKTREE_PATH" path=/src shift=true \
    --project "$INCUS_PROJECT" >/dev/null
  incus config device add "$name" target disk \
    pool=default source="$TARGET_VOLUME" path=/target \
    --project "$INCUS_PROJECT" >/dev/null
  incus config device add "$name" cargo-cache disk \
    pool=default source=cargo-registry path=/root/.cargo/registry \
    --project "$INCUS_PROJECT" >/dev/null
}

ensure_postgres_instance() {
  local name=postgres
  if incus_instance_exists "$INCUS_PROJECT" "$name"; then
    return 0
  fi
  info "init postgres from incus-dev-warm-pg (data is volatile)"
  # postgres data は instance エフェメラル FS。down.sh で消えて毎回まっさら。
  # staging の Cloud Run sidecar (emptyDir) と同じセマンティクス。
  incus init incus-dev-warm-pg "$name" \
    --project "$INCUS_PROJECT" \
    --profile default \
    --profile alc-base
}

start_instance() {
  local name="$1"
  local state
  state="$(incus list --project "$INCUS_PROJECT" --format=csv -c ns "$name" | cut -d, -f2 || true)"
  if [[ "$state" != "RUNNING" ]]; then
    info "starting $name"
    incus start "$name" --project "$INCUS_PROJECT"
  fi
}

# Write env file + systemd unit + (optional) migrate unit, then start the unit.
deploy_service_unit() {
  local instance="$1"
  local svc_key="$2"   # manifest key (backend / tenko / ...)

  local binary pre_start
  binary="$(svc="$svc_key" yq -r '.services[strenv(svc)].binary' "$MANIFEST")"
  pre_start="$(svc="$svc_key" yq -r '.services[strenv(svc)].pre_start // ""' "$MANIFEST")"

  # /etc/alc-service@<binary>.env
  local env_block
  env_block="$(svc="$svc_key" yq -r \
    '.services[strenv(svc)].env | to_entries | map("\(.key)=\(.value)") | .[]' "$MANIFEST")"
  printf '%s\n' "$env_block" \
    | incus exec "$instance" --project "$INCUS_PROJECT" -- \
        tee "/etc/alc-service@${binary}.env" >/dev/null

  # alc-service@<bin>.service
  incus file push --project "$INCUS_PROJECT" \
    "${SANDBOX_ROOT}/units/alc-service@.service.tmpl" \
    "${instance}/etc/systemd/system/alc-service@.service" --mode 0644

  # alc-migrate@<bin>.service (if pre_start declared)
  if [[ -n "$pre_start" ]]; then
    incus file push --project "$INCUS_PROJECT" \
      "${SANDBOX_ROOT}/units/alc-migrate@.service.tmpl" \
      "${instance}/etc/systemd/system/alc-migrate@.service" --mode 0644
    incus exec "$instance" --project "$INCUS_PROJECT" -- \
      systemctl enable --now "alc-migrate@${binary}.service" || warn "migrate failed for $svc_key"
  fi

  incus exec "$instance" --project "$INCUS_PROJECT" -- \
    systemctl enable --now "alc-service@${binary}.service"
}

# ---- launch services in dependency order ----
for svc in "${SERVICES[@]}"; do
  case "$svc" in
    postgres)
      ensure_postgres_instance
      start_instance postgres
      # postgres は cloud-init で自動起動。init SQL 流し込みのみ追加。
      info "applying init SQL to postgres (idempotent)"
      local init_sql_rel
      init_sql_rel="$(yq -r '.init_sql_path // "scripts/init_local_db.sql"' "$MANIFEST")"
      local init_sql_host="${WORKTREE_PATH}/${init_sql_rel}"
      if [[ -f "$init_sql_host" ]]; then
        # postgres ready まで待つ + psql で流す
        for i in 1 2 3 4 5 6 7 8 9 10; do
          incus exec postgres --project "$INCUS_PROJECT" -- pg_isready -h /var/run/postgresql -U postgres >/dev/null 2>&1 && break
          sleep 1
        done
        incus file push --project "$INCUS_PROJECT" \
          "$init_sql_host" postgres/tmp/init_local_db.sql --mode 0644
        incus exec postgres --project "$INCUS_PROJECT" -- \
          su -c "psql -U postgres -f /tmp/init_local_db.sql" postgres >/dev/null 2>&1 \
          || warn "init SQL had errors (likely idempotent re-run)"
      else
        warn "init SQL not found at $init_sql_host"
      fi
      ;;
    gateway)
      ensure_app_instance gateway incus-dev-warm
      start_instance gateway
      wait_for_cloud_init "$INCUS_PROJECT" gateway
      deploy_service_unit gateway gateway
      ;;
    *)
      # backend / tenko / carins / dtako / etc.
      ensure_app_instance "$svc" incus-dev-warm
      start_instance "$svc"
      wait_for_cloud_init "$INCUS_PROJECT" "$svc"
      deploy_service_unit "$svc" "$svc"
      ;;
  esac
done

# ---- gateway proxy device (host:HOST_PORT -> gateway:8080) ----
if printf '%s\n' "${SERVICES[@]}" | grep -qx gateway; then
  if ! incus config device show gateway --project "$INCUS_PROJECT" | grep -q '^gw-listen:'; then
    info "exposing gateway on host 127.0.0.1:${HOST_PORT}"
    incus config device add gateway gw-listen proxy \
      listen="tcp:127.0.0.1:${HOST_PORT}" \
      connect="tcp:127.0.0.1:8080" \
      --project "$INCUS_PROJECT" >/dev/null
  fi
fi

# ---- summary ----
ok "sandbox up: project=$INCUS_PROJECT  port=${HOST_PORT}"
cat <<EOF

  Backend ready at: http://127.0.0.1:${HOST_PORT}

  Frontend hint:
    cd ~/js/alc-app
    NUXT_PUBLIC_API_BASE=http://127.0.0.1:${HOST_PORT} \\
      ~/js/.dev-proxy/up-wt.sh --quick alc-app ${WT}

  Backend shell:
    bash bin/exec.sh ${PROJECT} ${WT} backend

  Stop:
    bash bin/down.sh ${PROJECT} ${WT}

EOF
incus list --project "$INCUS_PROJECT"
