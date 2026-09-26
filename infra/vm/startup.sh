#!/usr/bin/env bash
# GCE startup-script for the Langfuse VM. Runs as root on every boot, so each
# step is idempotent. Terraform embeds this file in instance metadata; editing
# it changes the metadata in place (no VM replacement) and takes effect on the
# next boot.
set -euo pipefail

readonly DATA_DEV=/dev/disk/by-id/google-langfuse-data
readonly DATA_MNT=/mnt/disks/data
readonly APP_DIR="${DATA_MNT}/langfuse"

log() { echo "langfuse-startup: $*"; }

# 1. Data disk: format once, mount on every boot.
if ! blkid "${DATA_DEV}" >/dev/null 2>&1; then
  log "formatting ${DATA_DEV}"
  mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "${DATA_DEV}"
fi
mkdir -p "${DATA_MNT}"
if ! grep -q " ${DATA_MNT} " /etc/fstab; then
  uuid="$(blkid -s UUID -o value "${DATA_DEV}")"
  echo "UUID=${uuid} ${DATA_MNT} ext4 discard,defaults,nofail 0 2" >>/etc/fstab
fi
mountpoint -q "${DATA_MNT}" || mount "${DATA_MNT}"

# 2. Docker Engine and the Compose plugin from Docker's apt repository.
if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -yq ca-certificates curl rsync
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# 3. Ops Agent: disk and memory metrics for the Cloud Monitoring alerts.
if ! systemctl list-unit-files google-cloud-ops-agent.service >/dev/null 2>&1; then
  log "installing Ops Agent"
  curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh -o /tmp/add-ops-agent-repo.sh
  bash /tmp/add-ops-agent-repo.sh --also-install
fi

# 4. Bind-mount targets. ClickHouse runs as 101:101 and cannot chown itself.
mkdir -p "${APP_DIR}"/{deploy,postgres,redis,clickhouse/data,clickhouse/logs}
chown -R 101:101 "${APP_DIR}/clickhouse"

# 5. Start the stack once deploy-app.yml has shipped it at least once.
if [[ -x "${APP_DIR}/deploy/bin/up.sh" ]]; then
  log "starting Langfuse ($(cat "${APP_DIR}/deploy/REVISION" 2>/dev/null || echo unknown))"
  "${APP_DIR}/deploy/bin/up.sh"
else
  log "no deployment yet; run the deploy-app workflow"
fi
