#!/usr/bin/env bash
# Entry point for deploy-app.yml. The workflow copies deploy/ to a staging
# directory over IAP SSH and runs:
#
#   sudo bash <staging>/bin/install.sh <staging> <git-sha>
#
# It syncs the files onto the data disk (so a reboot or VM recreation starts
# the same revision), then pulls images and restarts changed services.
set -euo pipefail

readonly SRC="${1:?staging directory}"
readonly REVISION="${2:?git revision}"
readonly DATA_MNT=/mnt/disks/data
readonly TARGET="${DATA_MNT}/langfuse/deploy"

if ! mountpoint -q "${DATA_MNT}"; then
  echo "install: ${DATA_MNT} is not mounted; has vm/startup.sh finished?" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "install: docker is missing; has vm/startup.sh finished?" >&2
  exit 1
fi

mkdir -p "${TARGET}"
rsync -a --delete --exclude .env "${SRC}/" "${TARGET}/"
chmod +x "${TARGET}"/bin/*.sh
echo "${REVISION}" >"${TARGET}/REVISION"

"${TARGET}/bin/up.sh" --pull

# Old Langfuse images add up quickly on the 20 GB boot disk.
docker image prune -af --filter "until=168h" >/dev/null
echo "install: ${REVISION} is live"
