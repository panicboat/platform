#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
summarize="${here}/../summarize-manifest-diff.sh"
fixtures="${here}/fixtures"
failures=0

check() {
    local name="$1" base="$2" head="$3" expected="$4" actual
    if actual="$(bash "${summarize}" "${base}" "${head}" 2>&1)" && diff -u "${expected}" <(printf '%s\n' "${actual}"); then
        echo "ok - ${name}"
    else
        echo "not ok - ${name}"
        printf '%s\n' "${actual}" | sed 's/^/# /'
        failures=$((failures + 1))
    fi
}

check "reports image, CRD and resource changes" \
    "${fixtures}/summarize/base.yaml" "${fixtures}/summarize/head.yaml" "${fixtures}/summarize/expected.md"
check "reports no changes for identical manifests" \
    "${fixtures}/identical/manifest.yaml" "${fixtures}/identical/manifest.yaml" "${fixtures}/identical/expected.md"

exit "${failures}"
