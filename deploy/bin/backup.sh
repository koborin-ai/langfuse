#!/usr/bin/env bash
# Nightly off-GCP backup to R2 (`langfuse-backups`, 30-day lifecycle).
# Complements the daily data-disk snapshot, which stays inside GCP.
# Triggered by langfuse-backup.timer.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEPLOY_DIR
readonly AWS_CLI_IMAGE=docker.io/amazon/aws-cli:2.37.4
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
readonly STAMP

env_get() {
  grep -E "^$1=" "${DEPLOY_DIR}/.env" | tail -n1 | cut -d= -f2-
}

R2_ENDPOINT="$(env_get R2_ENDPOINT)"
BUCKET="$(env_get R2_BACKUP_BUCKET)"
KEY_ID="$(env_get R2_BACKUP_ACCESS_KEY_ID)"
SECRET="$(env_get R2_BACKUP_SECRET_ACCESS_KEY)"
readonly R2_ENDPOINT BUCKET KEY_ID SECRET

cd "${DEPLOY_DIR}"

echo "backup: postgres -> s3://${BUCKET}/postgres/${STAMP}.dump"
docker compose exec -T postgres pg_dump -U postgres -Fc postgres |
  docker run --rm -i \
    -e AWS_ACCESS_KEY_ID="${KEY_ID}" \
    -e AWS_SECRET_ACCESS_KEY="${SECRET}" \
    -e AWS_DEFAULT_REGION=auto \
    -e AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    "${AWS_CLI_IMAGE}" \
    s3 cp - "s3://${BUCKET}/postgres/${STAMP}.dump" --endpoint-url "${R2_ENDPOINT}"

# ClickHouse's native BACKUP streams straight to the S3-compatible endpoint.
echo "backup: clickhouse -> s3://${BUCKET}/clickhouse/${STAMP}/"
# shellcheck disable=SC2016 # $CLICKHOUSE_* expand inside the container
printf "BACKUP DATABASE default TO S3('%s', '%s', '%s')" \
  "${R2_ENDPOINT}/${BUCKET}/clickhouse/${STAMP}/" "${KEY_ID}" "${SECRET}" |
  docker compose exec -T clickhouse sh -c \
    'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD"'

echo "backup: done ${STAMP}"
