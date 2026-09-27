#!/usr/bin/env bash
# Sub-scripts run as separate processes and source 00-auth.sh individually.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
"${LIB_DIR}/10-k8s-cleanup.sh"
"${LIB_DIR}/30-destroy-stacks.sh"
"${LIB_DIR}/40-orphan-verify.sh"
