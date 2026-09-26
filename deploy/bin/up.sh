#!/usr/bin/env bash
# Renders .env from Secret Manager, installs the backup timer, and brings the
# Compose project up. Runs as root, from vm/startup.sh on every boot and from
# bin/install.sh on every deploy.
#
# Usage: up.sh [--pull]
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEPLOY_DIR
# gcloud ships as a snap on Ubuntu GCE images; startup-script PATH lacks it.
export PATH="/snap/bin:${PATH}"

pull=false
[[ "${1:-}" == "--pull" ]] && pull=true

render_env() {
  local tmp="${DEPLOY_DIR}/.env.tmp"
  (
    umask 077
    {
      gcloud secrets versions access latest --secret=langfuse-env
      echo
      printf 'TUNNEL_TOKEN=%s\n' "$(gcloud secrets versions access latest --secret=cloudflared-token)"
    } >"${tmp}"
  )
  mv "${tmp}" "${DEPLOY_DIR}/.env"
}

install_units() {
  install -m 0644 "${DEPLOY_DIR}"/systemd/langfuse-backup.{service,timer} /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now langfuse-backup.timer
}

render_env
install_units

cd "${DEPLOY_DIR}"
if [[ "${pull}" == true ]]; then
  docker compose pull --quiet
fi
docker compose up -d --remove-orphans --wait --wait-timeout 600
docker compose ps
