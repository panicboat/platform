#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/render-comment.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export ACTION_TYPE=plan SERVICE_NAME=svc ENVIRONMENT=develop RUN_URL=https://github.com/o/r/actions/runs/1
failures=0

check() {
  local name=$1 haystack=$2 needle=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $name"
  else
    echo "not ok - $name: missing '$needle'"
    failures=$((failures + 1))
  fi
}

check_absent() {
  local name=$1 haystack=$2 needle=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $name"
  else
    echo "not ok - $name: unexpected '$needle'"
    failures=$((failures + 1))
  fi
}

printf 'No changes. Your infrastructure matches the configuration.\n' > "$tmp/success.log"
out=$(bash "$script" "$tmp/success.log" 0)
check "success status" "$out" "**Status**: ✅ Success"
check "success output" "$out" "No changes. Your infrastructure matches the configuration."
check_absent "no notice when the output fits" "$out" "Showing the last"

printf 'Error: creating S3 Bucket\n' > "$tmp/failure.log"
out=$(bash "$script" "$tmp/failure.log" 1)
check "failure status" "$out" "**Status**: ❌ Failed (exit code: 1)"
check "failure output" "$out" "Error: creating S3 Bucket"

out=$(bash "$script" "$tmp/missing.log" "")
check "status when terragrunt did not run" "$out" "**Status**: ❌ Failed before Terragrunt ran"
check "message when terragrunt did not run" "$out" "Terragrunt did not run. See the workflow logs."

printf '\033[1m\033[32mPlan:\033[0m 1 to add\n' > "$tmp/color.log"
out=$(bash "$script" "$tmp/color.log" 0)
check "strips ANSI escapes" "$out" "Plan: 1 to add"
check_absent "leaves no escape byte" "$out" $'\033'

# shellcheck disable=SC2016 # The expansions must stay literal to prove the script does not evaluate them.
literal='value with %41 and ${HOME} and `id` and ```'
printf '%s\n' "$literal" > "$tmp/literal.log"
out=$(bash "$script" "$tmp/literal.log" 0)
check "keeps percent, dollar and backticks literally" "$out" "$literal"

{ printf 'HEAD%.0s' {1..50}; printf 'Plan: 3 to add, 0 to change, 0 to destroy.\n'; } > "$tmp/long.log"
out=$(MAX_BYTES=60 bash "$script" "$tmp/long.log" 0)
check "keeps the tail of a long output" "$out" "Plan: 3 to add, 0 to change, 0 to destroy."
check_absent "drops the head of a long output" "$out" "HEADHEADHEADHEADHEAD"
check "links the run when truncated" "$out" "> ⚠️ Showing the last 60 bytes. [View full logs](https://github.com/o/r/actions/runs/1)"

exit "$failures"
