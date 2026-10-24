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

for side in base head; do
    if [ "${side}" = base ]; then args=("${fixtures}/invalid/manifest.yaml" "${fixtures}/identical/manifest.yaml"); else args=("${fixtures}/identical/manifest.yaml" "${fixtures}/invalid/manifest.yaml"); fi
    if bash "${summarize}" "${args[@]}" > /dev/null 2>&1; then
        echo "not ok - fails on an unparsable ${side} manifest"
        failures=$((failures + 1))
    else
        echo "ok - fails on an unparsable ${side} manifest"
    fi
done

exit "${failures}"
