#!/usr/bin/env bash
set -euo pipefail

base_ref="${1:?base revision required}"
out_dir="${2:?output directory required}"

cd "$(git rev-parse --show-toplevel)"
script_dir="$(pwd)/scripts/kubernetes-hydrate"
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
summary="${out_dir}/summary.md"

components="$(git diff --name-only --no-renames "${base_ref}" HEAD -- kubernetes/components/ | awk -F/ 'NF >= 5 { print $3 "/" $4 }' | sort -u)"
if [ -z "${components}" ]; then
    echo "No Kubernetes components changed." > "${summary}"
    exit 0
fi

work="$(mktemp -d)"
cleanup() {
    git worktree remove --force "${work}/base" 2>/dev/null || true # SILENT: the worktree may not exist when setup failed
    git worktree remove --force "${work}/head" 2>/dev/null || true # SILENT: the worktree may not exist when setup failed
    rm -rf "${work}"
}
trap cleanup EXIT
# Separate worktrees keep hydrate-component.sh from rewriting kubernetes/manifests in this checkout.
git worktree add -q --detach "${work}/base" "${base_ref}"
git worktree add -q --detach "${work}/head" HEAD

render() {
    local side="$1" svc="$2" env="$3" dir="$4"
    (cd "${work}/${side}" && bash "${script_dir}/hydrate-component.sh" "${svc}" "${env}") > "${dir}/${side}.log" 2>&1 &&
        cp "${work}/${side}/kubernetes/manifests/${env}/${svc}/manifest.yaml" "${dir}/${side}.yaml"
}

: > "${summary}"
for component in ${components}; do
    svc="${component%/*}"
    env="${component#*/}"
    dir="${out_dir}/${env}/${svc}"
    {
        echo "## ${svc} (${env})"
        echo
        if [ ! -f "aws/eks/${env}/env.hcl" ]; then
            echo "Not rendered: \`${env}\` has no \`aws/eks/${env}/env.hcl\`, so the hydrator never deploys it."
            echo
            continue
        fi
        mkdir -p "${dir}"
        failed=""
        render base "${svc}" "${env}" "${dir}" || failed="base"
        render head "${svc}" "${env}" "${dir}" || failed="${failed:+${failed} }head"
        if [ -n "${failed}" ]; then
            echo "Rendering failed (${failed}):"
            echo
            echo '```'
            for side in ${failed}; do
                tail -n 20 "${dir}/${side}.log"
            done
            echo '```'
        else
            diff -u "${dir}/base.yaml" "${dir}/head.yaml" > "${dir}/manifest.diff" || true # SILENT: diff exits 1 when the manifests differ
            echo "Full diff: \`${env}/${svc}/manifest.diff\`"
            echo
            if bash "${script_dir}/summarize-manifest-diff.sh" "${dir}/base.yaml" "${dir}/head.yaml" > "${dir}/summary.part" 2> "${dir}/summarize.log"; then
                cat "${dir}/summary.part"
            else
                echo "Summarizing failed; use the full diff:"
                echo
                echo '```'
                tail -n 20 "${dir}/summarize.log"
                echo '```'
            fi
        fi
        echo
    } >> "${summary}"
done
