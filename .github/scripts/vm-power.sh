#!/usr/bin/env bash
# Keeps the Langfuse VM on or off on purpose. The Spot-recovery Scheduler job
# `langfuse-start-vm` doubles as the record of intent: ENABLED means "keep
# Langfuse running" (restart after preemption), PAUSED means "stopped on
# purpose". The uptime alert policy follows the same switch so a deliberate
# stop does not page.
#
# Terraform ignores the job's `paused` flag and the policy's `enabled` flag,
# so apply and the release drift check pass in either state.
#
# Needs gcloud authenticated as langfuse-deployer, with a default project.
#
# Usage: vm-power.sh status|intent|start|stop
#   status  Markdown summary: intent, VM status, alert state
#   intent  prints "running" or "stopped"
#   start   resume the job, enable the alert, start the VM
#   stop    pause the job, disable the alert, stop the VM (waits)
set -euo pipefail

readonly ZONE="${ZONE:-asia-northeast1-b}"
readonly REGION="${REGION:-asia-northeast1}"
readonly INSTANCE="${INSTANCE:-langfuse}"
readonly JOB=langfuse-start-vm
readonly UPTIME_POLICY="Langfuse is unreachable"
readonly MONITORING_API=https://monitoring.googleapis.com/v3

log() { echo "vm-power: $*" >&2; }

vm_status() {
  gcloud compute instances describe "${INSTANCE}" --zone "${ZONE}" --format 'value(status)'
}

job_state() {
  gcloud scheduler jobs describe "${JOB}" --location "${REGION}" --format 'value(state)'
}

intent() {
  case "$(job_state)" in
    ENABLED) echo running ;;
    PAUSED) echo stopped ;;
    *) log "unexpected state for ${JOB}"; return 1 ;;
  esac
}

# gcloud has no GA command for alert policies, so this uses the REST API.
# Prints "<name> <enabled>" per matching policy.
uptime_policies() {
  local project token
  project="$(gcloud config get-value project 2>/dev/null)"
  token="$(gcloud auth print-access-token)"
  curl -fsS -H "Authorization: Bearer ${token}" \
    "${MONITORING_API}/projects/${project}/alertPolicies?pageSize=100" |
    jq -r --arg n "${UPTIME_POLICY}" \
      '.alertPolicies[]? | select(.displayName == $n) | "\(.name) \(.enabled // false)"'
}

set_uptime_alert() {
  local enabled="$1" policies token name
  policies="$(uptime_policies)"
  if [ -z "${policies}" ]; then
    log "alert policy '${UPTIME_POLICY}' not found"
    return 1
  fi
  token="$(gcloud auth print-access-token)"
  while read -r name _; do
    curl -fsS -X PATCH -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
      "${MONITORING_API}/${name}?updateMask=enabled" --data "{\"enabled\": ${enabled}}" >/dev/null
  done <<<"${policies}"
  log "uptime alert enabled=${enabled}"
}

start() {
  gcloud scheduler jobs resume "${JOB}" --location "${REGION}" --quiet
  log "Spot recovery resumed"
  set_uptime_alert true
  if [ "$(vm_status)" = RUNNING ]; then
    log "VM already running"
    return 0
  fi
  # Spot capacity can be short; the resumed job keeps retrying every 5 min.
  if ! gcloud compute instances start "${INSTANCE}" --zone "${ZONE}" --quiet; then
    echo "::warning::instances.start failed (likely no Spot capacity); Cloud Scheduler retries every 5 minutes."
  fi
}

stop() {
  # Pause first so the job cannot restart the VM while it shuts down.
  gcloud scheduler jobs pause "${JOB}" --location "${REGION}" --quiet
  log "Spot recovery paused"
  set_uptime_alert false
  case "$(vm_status)" in
    TERMINATED | STOPPED)
      log "VM already stopped"
      ;;
    *)
      # Runs infra/vm/shutdown.sh (compose stop) and waits for TERMINATED.
      gcloud compute instances stop "${INSTANCE}" --zone "${ZONE}" --quiet
      ;;
  esac
}

status() {
  local alert
  alert="$(uptime_policies | awk '{print $2}' | paste -sd, -)"
  cat <<EOF
| | |
| --- | --- |
| Intent (\`${JOB}\`) | $(intent) |
| VM \`${INSTANCE}\` | $(vm_status) |
| Uptime alert enabled | ${alert:-not found} |
EOF
}

case "${1:-}" in
  status) status ;;
  intent) intent ;;
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 status|intent|start|stop" >&2; exit 64 ;;
esac
