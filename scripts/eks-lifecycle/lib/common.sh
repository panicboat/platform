# common.sh - shared utilities for eks-lifecycle scripts.
#
# All numbered scripts (00-auth.sh ... 70-reconcile-watch.sh) source this
# file at the top to obtain logging, fail-fast, env validation, dry-run
# wrapper, and credential expiration tracking helpers.

# ----------------------------------------------------------------------------
# Fail-fast
# ----------------------------------------------------------------------------
set -euo pipefail

# ----------------------------------------------------------------------------
# Colors
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------------
# Logging functions
# ----------------------------------------------------------------------------
info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*" >&2; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# ----------------------------------------------------------------------------
# Environment / CLI validation
# ----------------------------------------------------------------------------
require_env() {
  if [ "${ENV:-}" != "production" ]; then
    error "ENV must be 'production' (got: '${ENV:-<unset>}')"
    exit 1
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "required command not found: $cmd"
      exit 1
    fi
  done
}

# ----------------------------------------------------------------------------
# y/N confirmation (always interactive, even when DRY_RUN=1)
# ----------------------------------------------------------------------------
confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
  fi
}

# ----------------------------------------------------------------------------
# DRY_RUN-aware command runner
# ----------------------------------------------------------------------------
# Usage: run aws ec2 describe-instances ...
# When DRY_RUN=1, prints the command without executing.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf "${YELLOW}[DRY-RUN]${NC} %s\n" "$*"
  else
    "$@"
  fi
}

# ----------------------------------------------------------------------------
# Repo root resolution (= for terragrunt invocations)
# ----------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
export REPO_ROOT

# ----------------------------------------------------------------------------
# AWS region from terragrunt env file (falls back to ap-northeast-1)
# ----------------------------------------------------------------------------
resolve_aws_region() {
  local env_file="${REPO_ROOT}/aws/eks/envs/${ENV}/env.hcl"
  if [ -f "$env_file" ]; then
    grep -E '^\s*aws_region\s*=' "$env_file" | head -1 | sed -E 's/^\s*aws_region\s*=\s*"([^"]+)".*/\1/'
  else
    echo "ap-northeast-1"
  fi
}

# ----------------------------------------------------------------------------
# Credentials expiration tracking
# ----------------------------------------------------------------------------
# 00-auth.sh writes UNIX epoch to this file when credentials are obtained.
# Subsequent steps check age and re-source 00-auth.sh if < 5 min remaining.
CREDS_EXPIRE_FILE="/tmp/eks-lifecycle-creds-expire-$$"
export CREDS_EXPIRE_FILE

creds_expiring_soon() {
  if [ ! -f "$CREDS_EXPIRE_FILE" ]; then
    return 0  # No record means we should re-auth
  fi
  local expire_at now remaining
  expire_at=$(cat "$CREDS_EXPIRE_FILE")
  now=$(date +%s)
  remaining=$((expire_at - now))
  if [ "$remaining" -lt 300 ]; then
    return 0  # Less than 5 min remaining
  fi
  return 1
}
