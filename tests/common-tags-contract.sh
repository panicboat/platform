#!/usr/bin/env bash
set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "$repository_root"

expected_common_tags="$(
  cat <<'EOF'
    Project     = local.project_name
    Environment = local.environment
    ManagedBy   = "terragrunt"
    Owner       = "panicboat"
    Repository  = "panicboat/platform"
EOF
)"

failures=0

fail() {
  printf '%s: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

extract_common_tags() {
  awk '
    /^locals \{/ { in_locals = 1; next }
    in_locals && /^}/ { in_locals = 0 }
    in_locals && /^  common_tags = \{/ { found = 1; in_block = 1; next }
    in_block && /^  }/ { in_block = 0 }
    in_block { print }
    END { exit found ? 0 : 3 }
  ' "$1"
}

extract_project_name() {
  sed -n '/^locals {/,/^}/s/^  project_name[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1"
}

checked_root_files=0

while IFS= read -r root_file; do
  extract_status=0
  common_tags_block="$(extract_common_tags "$root_file")" || extract_status=$?
  if test "$extract_status" -eq 3; then
    continue
  fi
  if test "$extract_status" -ne 0; then
    fail "$root_file" "failed to read the locals block"
    continue
  fi

  checked_root_files=$((checked_root_files + 1))

  expected_project_name="$(basename "$(dirname "$root_file")")"
  actual_project_name="$(extract_project_name "$root_file")"
  if test "$actual_project_name" != "$expected_project_name"; then
    fail "$root_file" "locals project_name must equal the directory name '$expected_project_name', found '$actual_project_name'"
  fi

  if test "$common_tags_block" != "$expected_common_tags"; then
    fail "$root_file" "locals common_tags must be exactly the five platform keys; diff (expected vs actual):"
    diff <(printf '%s\n' "$expected_common_tags") <(printf '%s\n' "$common_tags_block") >&2 || true
  fi
done < <(git ls-files '*root.hcl')

if test "$checked_root_files" -eq 0; then
  fail "root.hcl" "no root.hcl defines locals common_tags"
fi

while IFS= read -r stack_file; do
  if matches="$(grep -nE 'common_tags|environment_tags|additional_tags' "$stack_file")"; then
    fail "$stack_file" "must not define tags; tags are built only in root.hcl: $matches"
  fi
done < <(
  git ls-files aws github |
    grep -E '(^|/)(terragrunt|env)\.hcl$' |
    grep -Ev '(^|/)(modules|tests|\.terragrunt-cache)/' || true
)

if test "$failures" -gt 0; then
  exit 1
fi

echo "Common tags contract passed."
