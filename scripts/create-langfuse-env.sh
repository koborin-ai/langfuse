#!/usr/bin/env bash
# Generates the app .env and stores it as the first version of the
# `langfuse-env` secret, without writing it to disk or printing it. Run once,
# after the first `release-infra` apply has created the secret and the R2
# buckets.
#
# Refuses to run when the secret already has a version: regenerating SALT or
# ENCRYPTION_KEY would break stored API keys and encrypted credentials. Change
# individual values later with `gcloud secrets versions add` instead.
#
# Requires gcloud with access to n-koborinai and:
#   CLOUDFLARE_ACCOUNT_ID
#   LANGFUSE_OWNER_EMAIL       becomes the headless-init admin user
#   R2_APP_ACCESS_KEY_ID       R2 API token with Object Read & Write on
#   R2_APP_SECRET_ACCESS_KEY   langfuse-blob and langfuse-backups only
#
# The admin password is generated and kept only in the secret:
#   gcloud secrets versions access latest --secret=langfuse-env --project=n-koborinai \
#     | grep '^LANGFUSE_INIT_USER_PASSWORD='
set -euo pipefail

readonly PROJECT_ID=n-koborinai
readonly SECRET=langfuse-env

: "${CLOUDFLARE_ACCOUNT_ID:?}"
: "${LANGFUSE_OWNER_EMAIL:?}"
: "${R2_APP_ACCESS_KEY_ID:?}"
: "${R2_APP_SECRET_ACCESS_KEY:?}"

if [[ -n "$(gcloud secrets versions list "${SECRET}" --project="${PROJECT_ID}" --limit=1 --format='value(name)')" ]]; then
  echo "create-langfuse-env: ${SECRET} already has a version; not overwriting it" >&2
  exit 1
fi

hex() { openssl rand -hex 32; }

{
  cat <<EOF
NEXTAUTH_URL=https://langfuse.koborin.ai
NEXTAUTH_SECRET=$(hex)
SALT=$(hex)
ENCRYPTION_KEY=$(hex)
POSTGRES_PASSWORD=$(hex)
CLICKHOUSE_PASSWORD=$(hex)
REDIS_AUTH=$(hex)
R2_ENDPOINT=https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com
R2_BLOB_BUCKET=langfuse-blob
R2_BACKUP_BUCKET=langfuse-backups
R2_ACCESS_KEY_ID=${R2_APP_ACCESS_KEY_ID}
R2_SECRET_ACCESS_KEY=${R2_APP_SECRET_ACCESS_KEY}
AUTH_DISABLE_SIGNUP=true
AUTH_DISABLE_USERNAME_PASSWORD=false
LANGFUSE_INIT_ORG_ID=koborin-ai
LANGFUSE_INIT_ORG_NAME=koborin.ai
LANGFUSE_INIT_PROJECT_ID=showcase
LANGFUSE_INIT_PROJECT_NAME=showcase
LANGFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-$(openssl rand -hex 16)
LANGFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-$(openssl rand -hex 16)
LANGFUSE_INIT_USER_EMAIL=${LANGFUSE_OWNER_EMAIL}
LANGFUSE_INIT_USER_NAME=owner
LANGFUSE_INIT_USER_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
TELEMETRY_ENABLED=false
EOF
} | gcloud secrets versions add "${SECRET}" --project="${PROJECT_ID}" --data-file=- >/dev/null

echo "create-langfuse-env: stored the first version of ${SECRET}"
echo "Keep an offline copy of SALT and ENCRYPTION_KEY (e.g. 1Password)."
