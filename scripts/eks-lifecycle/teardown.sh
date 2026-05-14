#!/usr/bin/env bash
# teardown.sh - Top-level entry: run all teardown steps in order.
# Equivalent to: make eks-teardown-k8s + eks-teardown-aws + eks-teardown-verify
#
# Each sub-script sources 00-auth.sh internally, so we don't need to
# manage auth here. Sub-scripts run as separate bash processes via the
# Makefile too, so this entry mirrors that behavior.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
"${LIB_DIR}/10-k8s-cleanup.sh"
"${LIB_DIR}/30-destroy-stacks.sh"
"${LIB_DIR}/40-orphan-verify.sh"
