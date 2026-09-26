#!/usr/bin/env bash
# Runs `terraform plan -out=<file>` without printing the diff, then prints only
# the action and address of each changed resource. The repository and its
# Actions logs are public; full plan output would show attribute values.
#
# Usage: tf-plan-summary.sh <plan-file> [extra terraform plan args...]
# Exit code: 0 no changes, 2 changes present (terraform -detailed-exitcode).
set -uo pipefail

readonly PLAN_FILE="${1:?plan file}"
shift

set +e
terraform plan -input=false -no-color -detailed-exitcode -out="${PLAN_FILE}" "$@" >/dev/null
status=$?
set -e

if [[ "${status}" -eq 1 ]]; then
  echo "terraform plan failed; rerun locally with the same inputs to see the error" >&2
  exit 1
fi

summary="$(
  terraform show -json "${PLAN_FILE}" |
    jq -r '.resource_changes[]? | select(.change.actions != ["no-op"])
      | "\(.change.actions | join("+"))\t\(.address)"'
)"

{
  echo "## Terraform plan (addresses only)"
  echo
  if [[ -z "${summary}" ]]; then
    echo "No changes."
  else
    echo '```text'
    echo "${summary}"
    echo '```'
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "${status}"
