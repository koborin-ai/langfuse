#!/usr/bin/env bash
# Configures koborin-ai/langfuse on GitHub: variables, secrets, public
# visibility, main-only environments, branch protection, and Actions
# settings. Idempotent; safe to re-run.
#
# Requires `gh` authenticated as a repository admin (GH_TOKEN works) and:
#   CLOUDFLARE_ACCOUNT_ID   Cloudflare account ID
#   CLOUDFLARE_API_TOKEN    the one Cloudflare token (README "Cloudflare token")
#   LANGFUSE_OWNER_EMAIL    Access / alert address; stored as a secret only
#
# Usage: scripts/setup-github.sh
set -euo pipefail

readonly REPO="${REPO:-koborin-ai/langfuse}"
readonly GCP_WORKLOAD_IDENTITY_PROVIDER="${GCP_WORKLOAD_IDENTITY_PROVIDER:-projects/98679215902/locations/global/workloadIdentityPools/github-actions-pool/providers/koborin-ai-langfuse}"
readonly GCP_PLAN_SERVICE_ACCOUNT="${GCP_PLAN_SERVICE_ACCOUNT:-langfuse-planner@n-koborinai.iam.gserviceaccount.com}"
readonly GCP_SERVICE_ACCOUNT="${GCP_SERVICE_ACCOUNT:-langfuse-deployer@n-koborinai.iam.gserviceaccount.com}"
readonly ENVIRONMENTS=("production (infra)" "production (app)")

: "${CLOUDFLARE_ACCOUNT_ID:?}"
: "${CLOUDFLARE_API_TOKEN:?}"
: "${LANGFUSE_OWNER_EMAIL:?}"

log() { echo "setup-github: $*"; }

log "variables"
gh variable set CLOUDFLARE_ACCOUNT_ID --repo "${REPO}" --body "${CLOUDFLARE_ACCOUNT_ID}"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --repo "${REPO}" --body "${GCP_WORKLOAD_IDENTITY_PROVIDER}"
gh variable set GCP_PLAN_SERVICE_ACCOUNT --repo "${REPO}" --body "${GCP_PLAN_SERVICE_ACCOUNT}"
gh variable set GCP_SERVICE_ACCOUNT --repo "${REPO}" --body "${GCP_SERVICE_ACCOUNT}"

log "secrets"
# Values go through stdin so they never appear in the process list.
printf '%s' "${CLOUDFLARE_API_TOKEN}" | gh secret set CLOUDFLARE_API_TOKEN --repo "${REPO}"
printf '%s' "${LANGFUSE_OWNER_EMAIL}" | gh secret set LANGFUSE_OWNER_EMAIL --repo "${REPO}"
for stale in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY; do
  gh secret delete "${stale}" --repo "${REPO}" 2>/dev/null || true
done

# Environment branch policies and branch protection are free on public
# repositories, so visibility changes first.
log "visibility: public"
gh repo edit "${REPO}" --visibility public --accept-visibility-change-consequences

for env in "${ENVIRONMENTS[@]}"; do
  log "environment: ${env} (main only)"
  encoded="$(jq -rn --arg v "${env}" '$v|@uri')"
  gh api -X PUT "repos/${REPO}/environments/${encoded}" --silent --input - <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
  existing="$(gh api "repos/${REPO}/environments/${encoded}/deployment-branch-policies" \
    --jq '[.branch_policies[] | select(.name == "main" and .type == "branch")] | length')"
  if [[ "${existing}" == "0" ]]; then
    gh api -X POST "repos/${REPO}/environments/${encoded}/deployment-branch-policies" \
      --silent -f name=main -f type=branch
  fi
done

log "branch protection: main (PR required, no force push, no deletion)"
gh api -X PUT "repos/${REPO}/branches/main/protection" --silent --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

log "actions: read-only default token, approval for external fork PRs"
gh api -X PUT "repos/${REPO}/actions/permissions/workflow" --silent \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "repos/${REPO}/actions/permissions/fork-pr-contributor-approval" --silent \
  -f approval_policy=all_external_contributors

log "done"
