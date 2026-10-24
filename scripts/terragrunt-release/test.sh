#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
work_root="$(mktemp -d)"
trap 'rm -rf "${work_root}"' EXIT

last_stderr=""

assert_eq() {
    local expected="$1" actual="$2"
    if [ "${expected}" != "${actual}" ]; then
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

assert_fails() {
    local stderr_file="${work_root}/stderr"
    if "$@" 2>"${stderr_file}"; then
        echo "  expected a non-zero exit: $*" >&2
        exit 1
    fi
    last_stderr="$(cat "${stderr_file}")"
}

assert_stderr_contains() {
    local needle="$1"
    if [[ "${last_stderr}" != *"${needle}"* ]]; then
        echo "  stderr does not contain: ${needle}" >&2
        echo "  stderr: ${last_stderr}" >&2
        exit 1
    fi
}

test_validate_accepts_merge_and_release() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt
    environments:
      master:
        apply_trigger: merge
      production:
        apply_trigger: release
YAML
    bash "${script_dir}/validate-apply-trigger.sh"
}

test_validate_rejects_missing_trigger() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt
    environments:
      master:
        apply_trigger: merge
      production:
        aws_region: ap-northeast-1
YAML
    assert_fails bash "${script_dir}/validate-apply-trigger.sh"
    assert_stderr_contains "environments.production.apply_trigger"
}

test_validate_rejects_unknown_value() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt
    environments:
      production:
        apply_trigger: relase
YAML
    assert_fails bash "${script_dir}/validate-apply-trigger.sh"
    assert_stderr_contains "(got 'relase')"
}

test_validate_ignores_non_terragrunt_stacks() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt
    environments:
      master:
        apply_trigger: merge
  - name: kubernetes
    paths:
      - "kubernetes/components/{service}/{environment}"
YAML
    bash "${script_dir}/validate-apply-trigger.sh"
}

test_repository_config_is_valid() {
    bash "${script_dir}/validate-apply-trigger.sh" "${repo_root}/workflow-config.yaml"
}

test_repository_config_never_merges_production() {
    local trigger
    trigger="$(yq '.stacks[] | select(.name == "terragrunt") | .environments.production.apply_trigger' "${repo_root}/workflow-config.yaml")"
    assert_eq "release" "${trigger}"
}

failed=0
for test_name in $(compgen -A function test_); do
    fixture="$(mktemp -d "${work_root}/fixture.XXXXXX")"
    set +e
    (set -e; cd "${fixture}"; "${test_name}")
    status=$?
    set -e
    if [ "${status}" -eq 0 ]; then
        echo "PASS: ${test_name}"
    else
        echo "FAIL: ${test_name}"
        failed=1
    fi
done

exit "${failed}"
