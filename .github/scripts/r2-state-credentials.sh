#!/usr/bin/env bash
# Derives S3 credentials for the R2 Terraform state backend from the one
# Cloudflare API token, so CI needs no separate R2 key pair:
#   Access Key ID     = the token's id (from /tokens/verify)
#   Secret Access Key = SHA-256 of the token value
# https://developers.cloudflare.com/r2/api/tokens/#get-s3-api-credentials-from-an-api-token
#
# Needs CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID. Exports
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY to later steps via GITHUB_ENV.
set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?}"
: "${CLOUDFLARE_ACCOUNT_ID:?}"

verify() {
  { curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" "$1" 2>/dev/null || true; } |
    jq -r '.result.id // empty'
}

# Account-owned tokens verify under the account; user tokens under /user.
token_id="$(verify "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/tokens/verify")"
if [[ -z "${token_id}" ]]; then
  token_id="$(verify "https://api.cloudflare.com/client/v4/user/tokens/verify")"
fi
if [[ -z "${token_id}" ]]; then
  echo "could not verify CLOUDFLARE_API_TOKEN" >&2
  exit 1
fi

secret="$(printf '%s' "${CLOUDFLARE_API_TOKEN}" | sha256sum | cut -d' ' -f1)"
echo "::add-mask::${secret}"

{
  echo "AWS_ACCESS_KEY_ID=${token_id}"
  echo "AWS_SECRET_ACCESS_KEY=${secret}"
} >>"${GITHUB_ENV:?}"
