#!/usr/bin/env bash
# GCE shutdown-script. Spot preemption leaves about 30 seconds, so stop the
# databases cleanly within 25 and let GCE finish the rest.
set -uo pipefail

readonly COMPOSE_FILE=/mnt/disks/data/langfuse/deploy/compose.yaml

if [[ -f "${COMPOSE_FILE}" ]] && command -v docker >/dev/null 2>&1; then
  docker compose -f "${COMPOSE_FILE}" stop -t 25
fi
