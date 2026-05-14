#!/usr/bin/env bash
# recreate.sh - Top-level entry: run all recreate steps in order.

set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
"${LIB_DIR}/50-apply-stacks.sh"
"${LIB_DIR}/60-flux-bootstrap.sh"
"${LIB_DIR}/70-reconcile-watch.sh"
