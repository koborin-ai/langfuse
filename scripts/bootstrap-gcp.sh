#!/usr/bin/env bash
# One-time GCP bootstrap for koborin-ai/langfuse: APIs, the Workload Identity
# Federation pool/provider, and the two CI service accounts. Idempotent; safe
# to re-run, and re-running upgrades a project bootstrapped by an earlier
# revision.
#
# - The provider accepts only this repository, pinned by its immutable ID, so
#   a deleted-and-recreated repository with the same name is not trusted.
# - langfuse-planner (read-only) is usable from any ref, for PR plans.
# - langfuse-deployer (read-write) is usable only from refs/heads/main.
#
# Run as a project owner: `gcloud auth login` (or an owner's ADC), then
# scripts/bootstrap-gcp.sh
set -euo pipefail

readonly PROJECT_ID=n-koborinai
readonly PROJECT_NUMBER=98679215902
readonly REPO=koborin-ai/langfuse
readonly REPO_ID=1388592925
readonly POOL=github-actions-pool
readonly PROVIDER=koborin-ai-langfuse
readonly POOL_PATH="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}"
readonly PLANNER="langfuse-planner@${PROJECT_ID}.iam.gserviceaccount.com"
readonly DEPLOYER="langfuse-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

log() { echo "bootstrap-gcp: $*"; }

gcloud config set project "${PROJECT_ID}"

log "APIs"
gcloud services enable \
  iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
  compute.googleapis.com iap.googleapis.com oslogin.googleapis.com \
  secretmanager.googleapis.com cloudscheduler.googleapis.com \
  monitoring.googleapis.com logging.googleapis.com

# A deleted pool or provider still answers `describe` (state DELETED, kept 30
# days) and has to be undeleted rather than created.
log "workload identity pool ${POOL}"
pool_state="$(gcloud iam workload-identity-pools describe "${POOL}" \
  --location=global --format='value(state)' 2>/dev/null || true)"
case "${pool_state}" in
  ACTIVE) ;;
  DELETED) gcloud iam workload-identity-pools undelete "${POOL}" --location=global ;;
  *) gcloud iam workload-identity-pools create "${POOL}" \
       --location=global --display-name="GitHub Actions" ;;
esac

log "workload identity provider ${PROVIDER}"
provider_flags=(
  --location=global
  --workload-identity-pool="${POOL}"
  --display-name="koborin-ai/langfuse"
  --issuer-uri="https://token.actions.githubusercontent.com"
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref"
  --attribute-condition="assertion.repository == '${REPO}' && assertion.repository_id == '${REPO_ID}'"
)
provider_state="$(gcloud iam workload-identity-pools providers describe "${PROVIDER}" \
  --location=global --workload-identity-pool="${POOL}" --format='value(state)' 2>/dev/null || true)"
case "${provider_state}" in
  DELETED)
    gcloud iam workload-identity-pools providers undelete "${PROVIDER}" \
      --location=global --workload-identity-pool="${POOL}"
    gcloud iam workload-identity-pools providers update-oidc "${PROVIDER}" "${provider_flags[@]}" ;;
  ACTIVE) gcloud iam workload-identity-pools providers update-oidc "${PROVIDER}" "${provider_flags[@]}" ;;
  *) gcloud iam workload-identity-pools providers create-oidc "${PROVIDER}" "${provider_flags[@]}" ;;
esac

ensure_sa() {
  gcloud iam service-accounts describe "$1@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1 ||
    gcloud iam service-accounts create "$1" --display-name="$2"
}

project_role() {
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:$1" --role="$2" --condition=None --quiet >/dev/null
}

log "planner ${PLANNER}"
ensure_sa langfuse-planner "koborin-ai/langfuse plan (read-only)"
gcloud iam service-accounts add-iam-policy-binding "${PLANNER}" --quiet >/dev/null \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_PATH}/attribute.repository/${REPO}"
for role in roles/viewer roles/iam.securityReviewer roles/secretmanager.viewer; do
  project_role "${PLANNER}" "${role}"
done

log "deployer ${DEPLOYER}"
ensure_sa langfuse-deployer "koborin-ai/langfuse apply and deploy (main only)"
gcloud iam service-accounts add-iam-policy-binding "${DEPLOYER}" --quiet >/dev/null \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_PATH}/attribute.ref/refs/heads/main"
# Earlier revisions let the deployer be impersonated from any ref.
gcloud iam service-accounts remove-iam-policy-binding "${DEPLOYER}" --quiet >/dev/null 2>&1 \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_PATH}/attribute.repository/${REPO}" || true

for role in \
  roles/compute.admin \
  roles/compute.osAdminLogin \
  roles/iap.tunnelResourceAccessor \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/secretmanager.admin \
  roles/cloudscheduler.admin \
  roles/monitoring.editor \
  roles/serviceusage.serviceUsageAdmin; do
  project_role "${DEPLOYER}" "${role}"
done

# Project IAM admin, but only for the two roles the stack grants the VM. The
# expression contains commas, which `--condition=KEY=VALUE,...` would split.
condition_file="$(mktemp)"
trap 'rm -f "${condition_file}"' EXIT
cat >"${condition_file}" <<'EOF'
title: langfuse-vm-roles-only
description: Deployer may grant only the Langfuse VM's logging and metrics roles.
expression: "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/logging.logWriter', 'roles/monitoring.metricWriter'])"
EOF
gcloud projects add-iam-policy-binding "${PROJECT_ID}" --quiet >/dev/null \
  --member="serviceAccount:${DEPLOYER}" \
  --role=roles/resourcemanager.projectIamAdmin \
  --condition-from-file="${condition_file}"

log "done"
echo "GCP_WORKLOAD_IDENTITY_PROVIDER=${POOL_PATH}/providers/${PROVIDER}"
echo "GCP_PLAN_SERVICE_ACCOUNT=${PLANNER}"
echo "GCP_SERVICE_ACCOUNT=${DEPLOYER}"
