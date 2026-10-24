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

test_release_service_parses_tag() {
    assert_eq "eks-holmesgpt" "$(bash "${script_dir}/release-service.sh" --tag eks-holmesgpt-v1.2.3)"
}

test_release_service_rejects_root_tag() {
    assert_fails bash "${script_dir}/release-service.sh" --tag v0.1.0
    assert_stderr_contains "::error::"
}

test_release_service_rejects_flux_tag() {
    assert_fails bash "${script_dir}/release-service.sh" --tag kubernetes-production
    assert_stderr_contains "::error::"
}

test_release_service_parses_branch() {
    assert_eq "vpc" "$(bash "${script_dir}/release-service.sh" --branch release-please--branches--main--components--vpc)"
}

test_release_service_rejects_root_branch() {
    assert_fails bash "${script_dir}/release-service.sh" --branch release-please--branches--main
    assert_stderr_contains "::error::"
}

test_release_service_error_is_single_line() {
    assert_fails bash "${script_dir}/release-service.sh" --tag $'vpc-v1.2.3\n::warning::x'
    assert_stderr_contains "::error::"
    assert_eq "1" "$(printf '%s\n' "${last_stderr}" | wc -l | tr -d ' ')"
}

write_release_config() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt-shared
    attributes: {}
  - name: terragrunt
    environments:
      master:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::111111111111:role/master-plan
        iam_role_apply: arn:aws:iam::111111111111:role/master-apply
        apply_trigger: merge
      production:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::222222222222:role/production-plan
        iam_role_apply: arn:aws:iam::222222222222:role/production-apply
        apply_trigger: release
      staging:
        aws_region: us-east-1
        iam_role_plan: arn:aws:iam::333333333333:role/staging-plan
        iam_role_apply: arn:aws:iam::333333333333:role/staging-apply
        apply_trigger: release
  - name: kubernetes
    paths:
      - "kubernetes/components/{service}/{environment}"
YAML
}

test_release_targets_lists_release_envs() {
    write_release_config
    mkdir -p aws/vpc/master aws/vpc/production
    local expected='[{"service":"vpc","environment":"production","working_directory":"aws/vpc/production","aws_region":"ap-northeast-1","iam_role_plan":"arn:aws:iam::222222222222:role/production-plan","iam_role_apply":"arn:aws:iam::222222222222:role/production-apply"}]'
    assert_eq "${expected}" "$(bash "${script_dir}/release-targets.sh" vpc)"
}

test_release_targets_skips_missing_dirs() {
    write_release_config
    mkdir -p aws/vpc/production
    local targets
    targets="$(bash "${script_dir}/release-targets.sh" vpc)"
    assert_eq "1" "$(jq 'length' <<<"${targets}")"
    assert_eq "production" "$(jq -r '.[0].environment' <<<"${targets}")"
}

test_release_targets_fails_without_targets() {
    write_release_config
    mkdir -p aws/route53/master
    assert_fails bash "${script_dir}/release-targets.sh" route53
    assert_stderr_contains "no release targets for route53"
}

write_service_release_config() {
    local service="$1" component="${2:-$1}" exclude_paths="${3:-[\"aws/$1/master\"]}"
    mkdir -p "aws/${service}"
    cat > "aws/${service}/release-please-config.json" <<JSON
{"packages":{"aws/${service}":{"release-type":"simple","component":"${component}","include-component-in-tag":true,"exclude-paths":${exclude_paths}}}}
JSON
    echo "{\"aws/${service}\":\"0.1.0\"}" > "aws/${service}/release-please-manifest.json"
}

test_check_configs_accepts_matching_set() {
    write_release_config
    mkdir -p aws/vpc/production aws/route53/master
    write_service_release_config vpc
    assert_eq "" "$(bash "${script_dir}/check-release-configs.sh" 2>&1)"
}

test_check_configs_rejects_missing_config() {
    write_release_config
    mkdir -p aws/eks/production
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains "aws/eks/release-please-config.json"
}

test_check_configs_rejects_orphan_config() {
    write_release_config
    mkdir -p aws/route53/master
    write_service_release_config route53
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains "aws/route53/release-please-config.json"
}

test_check_configs_rejects_wrong_component() {
    write_release_config
    mkdir -p aws/vpc/production
    write_service_release_config vpc eks
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains "aws/vpc: component must be vpc (got 'eks')"
}

test_check_configs_rejects_manifest_without_package() {
    write_release_config
    mkdir -p aws/vpc/production
    write_service_release_config vpc
    echo '{}' > aws/vpc/release-please-manifest.json
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains "aws/vpc/release-please-manifest.json"
    rm aws/vpc/release-please-manifest.json
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains "aws/vpc/release-please-manifest.json"
}

test_check_configs_rejects_incomplete_release_env() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt
    environments:
      production:
        apply_trigger: release
YAML
    mkdir -p aws/vpc/production
    write_service_release_config vpc
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains "vpc/production"
    assert_stderr_contains "aws_region"
    assert_stderr_contains "iam_role_plan"
    assert_stderr_contains "iam_role_apply"
}

test_check_configs_rejects_missing_exclude_paths() {
    write_release_config
    mkdir -p aws/vpc/production
    write_service_release_config vpc
    jq -c 'del(.packages["aws/vpc"]["exclude-paths"])' aws/vpc/release-please-config.json > config.tmp
    mv config.tmp aws/vpc/release-please-config.json
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains 'aws/vpc: exclude-paths must be ["aws/vpc/master"] (got null)'
}

test_check_configs_rejects_relative_exclude_paths() {
    write_release_config
    mkdir -p aws/vpc/production
    write_service_release_config vpc vpc '["master"]'
    assert_fails bash "${script_dir}/check-release-configs.sh"
    assert_stderr_contains 'aws/vpc: exclude-paths must be ["aws/vpc/master"]'
}

test_check_configs_accepts_exclude_paths_in_any_order() {
    cat > workflow-config.yaml <<'YAML'
stacks:
  - name: terragrunt
    environments:
      master:
        apply_trigger: merge
      develop:
        apply_trigger: merge
      production:
        aws_region: ap-northeast-1
        iam_role_plan: arn:aws:iam::222222222222:role/production-plan
        iam_role_apply: arn:aws:iam::222222222222:role/production-apply
        apply_trigger: release
YAML
    mkdir -p aws/vpc/production
    write_service_release_config vpc vpc '["aws/vpc/develop","aws/vpc/master"]'
    assert_eq "" "$(bash "${script_dir}/check-release-configs.sh" 2>&1)"
}

test_deploy_trigger_applies_only_merge_targets() {
    local expected="\${{ matrix.target.stack == 'terragrunt' && (github.event_name == 'pull_request' && 'plan' || (matrix.target.apply_trigger == 'merge' && 'apply' || '')) || '' }}"
    local actual
    actual="$(yq '.jobs.deploy-terragrunt.with.action-type' "${repo_root}/.github/workflows/auto-label--deploy-trigger.yaml")"
    assert_eq "${expected}" "${actual}"
}

test_deploy_trigger_excludes_shared_targets() {
    local job stack
    for job in deploy-terragrunt deploy-kubernetes; do
        stack="$(yq ".jobs.${job}.strategy.matrix.exclude[] | select(.target.stack == \"terragrunt-shared\") | .target.stack" "${repo_root}/.github/workflows/auto-label--deploy-trigger.yaml")"
        assert_eq "terragrunt-shared" "${stack}"
    done
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
